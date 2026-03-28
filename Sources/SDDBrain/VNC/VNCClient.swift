// VNCClient.swift
// SDDBrain — lightweight RFB 3.8 VNC client over TCP.
//
// Connects to the macOS built-in Screen Sharing server (127.0.0.1:5900),
// performs the RFB handshake, and provides framebuffer capture + input
// injection.  Designed for Swift 6 strict concurrency; all mutable state
// lives inside the actor.

import Foundation
import AppKit
import CoreGraphics

// MARK: - Public enums

public enum MouseButton: Sendable {
    case left, right, middle
}

public enum VNCError: Error, Sendable {
    case connectionFailed(String)
    case authFailed
    case protocolError(String)
}

// MARK: - StreamPair helper

/// Wraps Foundation InputStream/OutputStream and provides synchronous
/// read/write helpers used inside the actor.
private final class StreamPair: NSObject, StreamDelegate, @unchecked Sendable {
    let input: InputStream
    let output: OutputStream

    // Simple semaphore-based blocking read for the handshake phase.
    private let readSemaphore = DispatchSemaphore(value: 0)
    private var pendingData = Data()
    private let lock = NSLock()

    var isOpen: Bool = false

    init(host: String, port: Int) throws {
        var ins: InputStream?
        var outs: OutputStream?
        Stream.getStreamsToHost(withName: host,
                                port: port,
                                inputStream: &ins,
                                outputStream: &outs)
        guard let i = ins, let o = outs else {
            throw VNCError.connectionFailed("Could not create streams to \(host):\(port)")
        }
        input = i
        output = o
        super.init()
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .default)
        output.schedule(in: .main, forMode: .default)
        input.open()
        output.open()
        isOpen = true
    }

    func close() {
        input.close()
        output.close()
        isOpen = false
    }

    // MARK: StreamDelegate

    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if aStream === input && eventCode.contains(.hasBytesAvailable) {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = input.read(&buf, maxLength: buf.count)
            if n > 0 {
                lock.lock()
                pendingData.append(contentsOf: buf.prefix(n))
                lock.unlock()
                readSemaphore.signal()
            }
        }
    }

    // MARK: Read / Write

    /// Blocking read that waits until exactly `count` bytes are available.
    func readBytes(count: Int, timeout: TimeInterval = 10) throws -> Data {
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while collected.count < count {
            lock.lock()
            let available = pendingData
            pendingData = Data()
            lock.unlock()
            collected.append(available)
            if collected.count < count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw VNCError.connectionFailed("Read timed out waiting for \(count) bytes")
                }
                _ = readSemaphore.wait(timeout: .now() + min(remaining, 0.1))
                // Drain any bytes that arrived while we were waiting.
                lock.lock()
                let extra = pendingData
                pendingData = Data()
                lock.unlock()
                collected.append(extra)
            }
        }
        // If we read more than needed, put the excess back.
        if collected.count > count {
            let excess = collected.suffix(collected.count - count)
            lock.lock()
            pendingData.insert(contentsOf: excess, at: 0)
            lock.unlock()
            collected = collected.prefix(count)
        }
        return collected
    }

    /// Writes all bytes, blocking until complete.
    func writeBytes(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            guard output.hasSpaceAvailable else {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                continue
            }
            let written = remaining.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return output.write(base.assumingMemoryBound(to: UInt8.self),
                                    maxLength: remaining.count)
            }
            if written < 0 {
                throw VNCError.connectionFailed("Stream write error")
            }
            remaining = remaining.dropFirst(written)
        }
    }
}

// MARK: - VNCClient

public actor VNCClient {

    // MARK: State

    private var stream: StreamPair?
    private var serverWidth: UInt16 = 0
    private var serverHeight: UInt16 = 0
    private var connected: Bool = false

    // MARK: Init

    public init() {}

    // MARK: - Public API

    /// Establish a connection and complete the RFB 3.8 handshake.
    ///
    /// - Parameters:
    ///   - host: VNC server host (default `127.0.0.1`).
    ///   - port: VNC server port (default `5900`).
    ///   - password: Optional VNC password.  If the server requires a
    ///     password and none is provided the method throws ``VNCError/authFailed``.
    ///     For localhost use, disable the VNC password in System Settings →
    ///     General → Sharing → Screen Sharing → (info button) → disable
    ///     "VNC viewers may control screen with password".
    public func connect(
        host: String = "127.0.0.1",
        port: Int = 5900,
        password: String? = nil
    ) async throws {
        let pair: StreamPair
        do {
            pair = try StreamPair(host: host, port: port)
        } catch {
            throw VNCError.connectionFailed("Cannot open TCP connection to \(host):\(port) — \(error.localizedDescription)")
        }
        self.stream = pair

        // Allow streams to open (Foundation needs a run-loop spin).
        try await Task.sleep(nanoseconds: 50_000_000)

        // --- RFB ProtocolVersion handshake ---
        let serverVersion = try pair.readBytes(count: 12)
        let versionStr = String(bytes: serverVersion, encoding: .ascii) ?? ""
        guard versionStr.hasPrefix("RFB ") else {
            throw VNCError.protocolError("Server did not send RFB version banner: \(versionStr)")
        }

        // Send RFB 3.8
        let clientVersion = "RFB 003.008\n"
        try pair.writeBytes(clientVersion.data(using: .ascii)!)

        // --- Security negotiation ---
        let numSecTypes = try pair.readBytes(count: 1)[0]
        if numSecTypes == 0 {
            // Server sent a failure reason
            let reasonLenData = try pair.readBytes(count: 4)
            let reasonLen = Int(UInt32(bigEndian: reasonLenData.withUnsafeBytes { $0.load(as: UInt32.self) }))
            let reasonData = try pair.readBytes(count: reasonLen)
            let reason = String(bytes: reasonData, encoding: .utf8) ?? "unknown"
            throw VNCError.connectionFailed("Server refused connection: \(reason)")
        }

        let secTypes = try pair.readBytes(count: Int(numSecTypes))

        // Prefer security type 1 (None), fall back to 2 (VNC Auth).
        var chosenType: UInt8 = 0
        if secTypes.contains(1) {
            chosenType = 1
        } else if secTypes.contains(2) {
            chosenType = 2
        } else {
            throw VNCError.protocolError("No supported security type offered by server. Types: \(Array(secTypes))")
        }

        try pair.writeBytes(Data([chosenType]))

        // --- Handle chosen security type ---
        switch chosenType {
        case 1:
            // None — no further exchange needed before SecurityResult.
            break
        case 2:
            // VNC Authentication (DES challenge-response).
            guard let pwd = password else {
                throw VNCError.authFailed
            }
            let challenge = try pair.readBytes(count: 16)
            let response = try vncDesEncrypt(challenge: challenge, password: pwd)
            try pair.writeBytes(response)
        default:
            break
        }

        // --- SecurityResult (only sent in RFB 3.8 for type != None... actually sent always in 3.8) ---
        // RFB 3.8 always sends SecurityResult.
        let resultData = try pair.readBytes(count: 4)
        let result = UInt32(bigEndian: resultData.withUnsafeBytes { $0.load(as: UInt32.self) })
        if result != 0 {
            // Read failure reason
            let reasonLenData = try pair.readBytes(count: 4)
            let reasonLen = Int(UInt32(bigEndian: reasonLenData.withUnsafeBytes { $0.load(as: UInt32.self) }))
            let reasonData = try pair.readBytes(count: reasonLen)
            let reason = String(bytes: reasonData, encoding: .utf8) ?? "unknown"
            throw VNCError.authFailed
        }

        // --- ClientInit ---
        // shared-flag = 1 (allow other viewers)
        try pair.writeBytes(Data([1]))

        // --- ServerInit ---
        // framebuffer-width(2), framebuffer-height(2), pixel-format(16), name-length(4), name
        let serverInitHeader = try pair.readBytes(count: 24)
        serverWidth = UInt16(bigEndian: serverInitHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) })
        serverHeight = UInt16(bigEndian: serverInitHeader.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) })
        let nameLenData = try pair.readBytes(count: 4)
        let nameLen = Int(UInt32(bigEndian: nameLenData.withUnsafeBytes { $0.load(as: UInt32.self) }))
        if nameLen > 0 {
            _ = try pair.readBytes(count: nameLen)
        }

        connected = true
    }

    // MARK: Frame capture

    /// Requests a full framebuffer update, reads the raw pixel data, and
    /// returns a JPEG-encoded `Data` representation of the screen.
    public func captureFrame() async throws -> Data {
        guard connected, let pair = stream else {
            throw VNCError.connectionFailed("Not connected")
        }

        let w = serverWidth
        let h = serverHeight

        // Send FramebufferUpdateRequest (non-incremental, full frame, raw encoding).
        // We must first set the pixel format to something we understand.
        // Use Raw encoding (0) and rely on the server's native pixel format,
        // then request an update.

        // SetEncodings message: tell the server we support Raw (0).
        var setEnc = Data([2, 0])   // type=2 (SetEncodings), padding
        setEnc.append(bigEndian16: 1)  // number-of-encodings = 1
        setEnc.append(bigEndian32: 0)  // encoding type = Raw
        try pair.writeBytes(setEnc)

        // FramebufferUpdateRequest
        var req = Data([3])         // message type
        req.append(0)               // incremental = 0 (full)
        req.append(bigEndian16: 0)  // x-position
        req.append(bigEndian16: 0)  // y-position
        req.append(bigEndian16: w)  // width
        req.append(bigEndian16: h)  // height
        try pair.writeBytes(req)

        // Read FramebufferUpdate response.
        // Header: type(1), padding(1), number-of-rectangles(2)
        let header = try pair.readBytes(count: 4)
        guard header[0] == 0 else {
            throw VNCError.protocolError("Expected FramebufferUpdate (0), got \(header[0])")
        }
        let numRects = UInt16(bigEndian: header.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) })

        // Collect all pixel data (assuming Raw encoding, 32 bpp BGRA).
        var pixels = Data(count: Int(w) * Int(h) * 4)
        for _ in 0..<numRects {
            let rectHeader = try pair.readBytes(count: 12)
            let rx = UInt16(bigEndian: rectHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) })
            let ry = UInt16(bigEndian: rectHeader.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) })
            let rw = UInt16(bigEndian: rectHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) })
            let rh = UInt16(bigEndian: rectHeader.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) })
            let encoding = Int32(bigEndian: rectHeader.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) })

            guard encoding == 0 else {
                throw VNCError.protocolError("Unexpected encoding \(encoding) in FramebufferUpdate")
            }

            let byteCount = Int(rw) * Int(rh) * 4
            let rectPixels = try pair.readBytes(count: byteCount)

            // Blit rect into the full-frame buffer.
            for row in 0..<Int(rh) {
                let srcOffset = row * Int(rw) * 4
                let dstRow = Int(ry) + row
                let dstOffset = (dstRow * Int(w) + Int(rx)) * 4
                let srcRange = srcOffset..<(srcOffset + Int(rw) * 4)
                let dstRange = dstOffset..<(dstOffset + Int(rw) * 4)
                if dstRange.upperBound <= pixels.count && srcRange.upperBound <= rectPixels.count {
                    pixels[dstRange] = rectPixels[srcRange]
                }
            }
        }

        // Convert raw BGRA pixels to JPEG via NSBitmapImageRep.
        return try rawBGRAToJPEG(pixels: pixels, width: Int(w), height: Int(h))
    }

    // MARK: Mouse / pointer

    /// Sends a click at the given VNC framebuffer pixel coordinates.
    public func click(x: Int, y: Int, button: MouseButton = .left) async {
        guard let pair = stream else { return }
        let mask = button.mask
        // Press
        let press = pointerEvent(buttonMask: mask, x: x, y: y)
        try? pair.writeBytes(press)
        // Release
        let release = pointerEvent(buttonMask: 0, x: x, y: y)
        try? pair.writeBytes(release)
    }

    /// Sends scroll events at the given coordinates.
    public func scroll(x: Int, y: Int, direction: ScrollDirection, amount: Int = 3) async {
        guard let pair = stream else { return }
        let mask = direction.buttonMask
        for _ in 0..<amount {
            let press = pointerEvent(buttonMask: mask, x: x, y: y)
            try? pair.writeBytes(press)
            let release = pointerEvent(buttonMask: 0, x: x, y: y)
            try? pair.writeBytes(release)
        }
    }

    /// Types a string by sending individual KeyEvent messages for each character.
    public func typeText(_ text: String) async {
        for char in text.unicodeScalars {
            await pressKey(char.value, down: true)
            await pressKey(char.value, down: false)
        }
    }

    /// Sends a single RFB KeyEvent.
    public func pressKey(_ keysym: UInt32, down: Bool) async {
        guard let pair = stream else { return }
        var msg = Data([4])                    // message type
        msg.append(down ? 1 : 0)              // down-flag
        msg.append(contentsOf: [0, 0])        // padding
        msg.append(bigEndian32: keysym)       // key-sym
        try? pair.writeBytes(msg)
    }

    // MARK: Connection management

    public func disconnect() {
        stream?.close()
        stream = nil
        connected = false
    }

    public func isConnected() -> Bool {
        connected
    }

    // MARK: - Private helpers

    private func pointerEvent(buttonMask: UInt8, x: Int, y: Int) -> Data {
        var msg = Data([5])              // message type = PointerEvent
        msg.append(buttonMask)
        msg.append(bigEndian16: UInt16(clamping: x))
        msg.append(bigEndian16: UInt16(clamping: y))
        return msg
    }

    private func rawBGRAToJPEG(pixels: Data, width: Int, height: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            throw VNCError.protocolError("Could not create NSBitmapImageRep")
        }

        // Copy pixel data. NSBitmapImageRep expects RGBA; VNC Raw sends BGRA.
        // Swap B and R channels.
        guard let bitmapBytes = rep.bitmapData else {
            throw VNCError.protocolError("NSBitmapImageRep has no bitmapData")
        }
        pixels.withUnsafeBytes { src in
            let srcPtr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let total = width * height * 4
            for i in stride(from: 0, to: total, by: 4) {
                bitmapBytes[i + 0] = srcPtr[i + 2] // R ← B
                bitmapBytes[i + 1] = srcPtr[i + 1] // G ← G
                bitmapBytes[i + 2] = srcPtr[i + 0] // B ← R
                bitmapBytes[i + 3] = srcPtr[i + 3] // A ← A
            }
        }

        let props: [NSBitmapImageRep.PropertyKey: Any] = [
            .compressionFactor: 0.85
        ]
        guard let jpeg = rep.representation(using: .jpeg, properties: props) else {
            throw VNCError.protocolError("Could not encode JPEG")
        }
        return jpeg
    }

    // MARK: - VNC DES Authentication

    /// Encrypts a 16-byte RFB challenge using the provided password.
    /// RFB uses DES with bit-reversed key bytes.
    private func vncDesEncrypt(challenge: Data, password: String) throws -> Data {
        // Prepare the 8-byte DES key from the password (pad/truncate, bit-reverse each byte).
        var key = [UInt8](repeating: 0, count: 8)
        let pwBytes = Array(password.utf8.prefix(8))
        for i in 0..<min(pwBytes.count, 8) {
            key[i] = reverseBits(pwBytes[i])
        }

        // Encrypt the challenge as two 8-byte DES ECB blocks.
        let block1 = try desEncryptBlock(Array(challenge.prefix(8)), key: key)
        let block2 = try desEncryptBlock(Array(challenge.suffix(8)), key: key)
        return Data(block1 + block2)
    }

    private func reverseBits(_ byte: UInt8) -> UInt8 {
        var b = byte
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = (result << 1) | (b & 1)
            b >>= 1
        }
        return result
    }

    /// Minimal single-block DES ECB encryption (no external library dependency).
    /// This is a standard textbook DES implementation sufficient for RFB auth.
    private func desEncryptBlock(_ block: [UInt8], key: [UInt8]) throws -> [UInt8] {
        // Use CommonCrypto via CCCrypt for DES ECB encryption.
        // CommonCrypto is available on all Apple platforms without import.
        guard block.count == 8, key.count == 8 else {
            throw VNCError.authFailed
        }
        var output = [UInt8](repeating: 0, count: 8)
        var numBytesEncrypted = 0

        // kCCAlgorithmDES = 1, kCCOptionECBMode = 2, kCCEncrypt = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            block.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        0,      // kCCEncrypt
                        1,      // kCCAlgorithmDES
                        2,      // kCCOptionECBMode (no padding implied by exact block size)
                        keyPtr.baseAddress, 8,
                        nil,    // no IV for ECB
                        inPtr.baseAddress, 8,
                        outPtr.baseAddress, 8,
                        &numBytesEncrypted
                    )
                }
            }
        }

        guard status == 0 /* kCCSuccess */ else {
            throw VNCError.authFailed
        }
        return output
    }
}

// MARK: - MouseButton / ScrollDirection helpers

private extension MouseButton {
    var mask: UInt8 {
        switch self {
        case .left:   return 1
        case .middle: return 2
        case .right:  return 4
        }
    }
}

private extension ScrollDirection {
    /// RFB uses button 6 (mask 32) for scroll-up and button 7 (mask 64) for scroll-down.
    /// Some implementations use 8/16; the common convention is:
    ///   scroll up   = button 4 (mask 8)
    ///   scroll down = button 5 (mask 16)
    ///   scroll left = button 6 (mask 32)
    ///   scroll right= button 7 (mask 64)
    var buttonMask: UInt8 {
        switch self {
        case .up:    return 8
        case .down:  return 16
        case .left:  return 32
        case .right: return 64
        }
    }
}

// MARK: - Data big-endian append helpers

private extension Data {
    mutating func append(bigEndian16 value: UInt16) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian32 value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

// MARK: - CommonCrypto declaration
// CCCrypt is part of the Security/CommonCrypto framework present on all
// Apple platforms.  We declare it here to avoid needing a bridging header.

@_silgen_name("CCCrypt")
private func CCCrypt(
    _ op: UInt32,
    _ alg: UInt32,
    _ options: UInt32,
    _ key: UnsafeRawPointer?,
    _ keyLength: Int,
    _ iv: UnsafeRawPointer?,
    _ dataIn: UnsafeRawPointer?,
    _ dataInLength: Int,
    _ dataOut: UnsafeMutableRawPointer?,
    _ dataOutAvailable: Int,
    _ dataOutMoved: UnsafeMutablePointer<Int>?
) -> Int32

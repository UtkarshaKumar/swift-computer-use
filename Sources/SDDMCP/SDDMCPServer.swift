import Foundation

/// SDD MCP Server — JSON-RPC 2.0 over stdio.
///
/// Transport auto-detection (GhostOS pattern):
///   - First byte 'C' (0x43) → Content-Length framing (Claude Code)
///   - First byte '{' (0x7B) → NDJSON line framing (Claude Desktop)
///
/// stdout is pre-redirected to the saved fd by main.swift before this runs.
/// All diagnostic output goes to stderr via fputs (never print).
public final class SDDMCPServer {
    private let mcpOutput: FileHandle
    private var transport: Transport = .unknown

    private enum Transport {
        case unknown
        case contentLength
        case ndjson
    }

    /// One-byte peek buffer used during transport detection.
    private var peekedByte: UInt8? = nil

    public init(output: FileHandle) {
        self.mcpOutput = output
    }

    // MARK: - Main run loop

    public func run() {
        fputs("[sdd-mcp] Server started — waiting for first message\n", stderr)
        while true {
            guard let message = readMessage() else {
                fputs("[sdd-mcp] Read returned nil — stdin closed, exiting\n", stderr)
                break
            }

            let id = message["id"] ?? NSNull()
            let method = message["method"] as? String ?? ""
            let params  = message["params"] as? [String: Any] ?? [:]

            fputs("[sdd-mcp] method=\(method)\n", stderr)

            switch method {
            case "initialize":
                writeResponse(id: id, result: handleInitialize(params))

            case "notifications/initialized":
                // No response required for notifications
                break

            case "ping":
                writeResponse(id: id, result: [:])

            case "tools/list":
                writeResponse(id: id, result: ["tools": SDDMCPTools.definitions()])

            case "tools/call":
                let toolName = params["name"] as? String ?? ""
                let toolArgs = params["arguments"] as? [String: Any] ?? [:]
                var callParams = toolArgs
                callParams["_tool"] = toolName
                let result = SDDMCPTools.handle(callParams)
                writeResponse(id: id, result: result)

            default:
                writeError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Transport detection + message reading

    private func readMessage() -> [String: Any]? {
        // Detect transport on the very first read
        if transport == .unknown {
            guard let firstByte = readOneByte() else { return nil }
            if firstByte == 0x43 {  // 'C' — Content-Length header
                transport = .contentLength
                peekedByte = firstByte
                fputs("[sdd-mcp] Transport: Content-Length (Claude Code)\n", stderr)
            } else if firstByte == 0x7B {  // '{' — NDJSON
                transport = .ndjson
                peekedByte = firstByte
                fputs("[sdd-mcp] Transport: NDJSON (Claude Desktop)\n", stderr)
            } else {
                fputs("[sdd-mcp] Unknown first byte 0x\(String(firstByte, radix: 16)) — assuming NDJSON\n", stderr)
                transport = .ndjson
                peekedByte = firstByte
            }
        }

        switch transport {
        case .contentLength:
            return readContentLengthMessage()
        case .ndjson, .unknown:
            return readNDJSONMessage()
        }
    }

    /// Read Content-Length framed message: headers + blank line + body.
    private func readContentLengthMessage() -> [String: Any]? {
        // Read headers line by line until blank line
        var contentLength: Int = 0
        while true {
            guard let line = readLine(includingPeeked: true) else { return nil }
            if line.isEmpty { break }  // blank line separates headers from body
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
            // Ignore other headers (Content-Type, etc.)
        }

        guard contentLength > 0 else {
            fputs("[sdd-mcp] Content-Length is 0 or missing\n", stderr)
            return nil
        }

        guard let bodyData = readBytes(count: contentLength) else { return nil }
        return parseJSON(bodyData)
    }

    /// Read NDJSON message: one complete line of JSON.
    private func readNDJSONMessage() -> [String: Any]? {
        guard let line = readLine(includingPeeked: true) else { return nil }
        guard !line.isEmpty else { return readNDJSONMessage() }  // skip blank lines
        guard let data = line.data(using: .utf8) else { return nil }
        return parseJSON(data)
    }

    // MARK: - Low-level I/O

    private func readOneByte() -> UInt8? {
        let data = FileHandle.standardInput.readData(ofLength: 1)
        guard data.count == 1 else { return nil }
        return data[0]
    }

    /// Read a CRLF- or LF-terminated line. Drains the peekedByte first.
    private func readLine(includingPeeked: Bool) -> String? {
        var bytes: [UInt8] = []

        // Prepend the peeked byte if present
        if includingPeeked, let b = peekedByte {
            peekedByte = nil
            if b == 0x0A { return "" }  // LF alone = empty line
            bytes.append(b)
        }

        while true {
            let data = FileHandle.standardInput.readData(ofLength: 1)
            guard data.count == 1 else {
                if bytes.isEmpty { return nil }
                break
            }
            let byte = data[0]
            if byte == 0x0A { break }          // LF — end of line
            if byte == 0x0D { continue }       // CR — skip (part of CRLF)
            bytes.append(byte)
        }

        return String(bytes: bytes, encoding: .utf8)
    }

    /// Read exactly `count` bytes from stdin.
    private func readBytes(count: Int) -> Data? {
        var buffer = Data()
        var remaining = count
        while remaining > 0 {
            let chunk = FileHandle.standardInput.readData(ofLength: remaining)
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            remaining -= chunk.count
        }
        return buffer
    }

    private func parseJSON(_ data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            fputs("[sdd-mcp] JSON parse error for \(data.count) bytes\n", stderr)
            return nil
        }
        return dict
    }

    // MARK: - Response writing

    private func writeResponse(id: Any, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        writeJSON(response)
    }

    private func writeError(id: Any, code: Int, message: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        writeJSON(response)
    }

    private func writeJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            fputs("[sdd-mcp] Failed to serialize response\n", stderr)
            return
        }

        switch transport {
        case .contentLength, .unknown:
            // Content-Length framing
            let header = "Content-Length: \(data.count)\r\n\r\n"
            let headerData = header.data(using: .utf8)!
            mcpOutput.write(headerData)
            mcpOutput.write(data)

        case .ndjson:
            // NDJSON: one JSON object per line
            var lineData = data
            lineData.append(0x0A)  // newline
            mcpOutput.write(lineData)
        }
    }

    // MARK: - initialize handler

    private func handleInitialize(_ params: [String: Any]) -> [String: Any] {
        return [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "SDD", "version": "1.0.0"],
            "instructions": """
            SDD gives you a high-speed VNC+ShowUI-2B computer-use agent on macOS.
            Rule 1: Call sdd_run to start a task. Call sdd_status to monitor. Call sdd_override to intervene mid-run.
            Rule 2: Use sdd_execute for single one-off actions without a full run loop.
            Rule 3: Use sdd_screenshot to see the current screen state at any time.
            Rule 4: sdd_record teaches SDD new workflows by watching you demonstrate them once.
            Rule 5: If a run is going wrong, call sdd_override with corrective instruction, or sdd_intervene to take direct control for one step.
            """,
        ]
    }
}

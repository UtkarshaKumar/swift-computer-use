import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import VideoToolbox
import Combine

public enum CaptureError: Error {
    case permissionDenied
    case noDisplayFound
    case noWindowFound
    case streamStartFailed(String)
}

public enum CaptureTarget {
    case fullScreen(SCDisplay)
    case window(SCWindow)
    case region(SCDisplay, CGRect)
}

public protocol ScreenCaptureDelegate: AnyObject {
    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer)
}

public class ScreenCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    public var frameRate: Int = 30
    public var changeThreshold: Double = 0.05 // 5% pixel change
    
    private let frameSubject = PassthroughSubject<CMSampleBuffer, Never>()
    public var framePublisher: AnyPublisher<CMSampleBuffer, Never> {
        frameSubject.eraseToAnyPublisher()
    }
    
    private var lastHash: [UInt64]?
    private let hashResolution = 16 // 16x16 grid for perceptual hash
    
    public override init() {
        super.init()
    }
    
    public func startCapture(target: CaptureTarget) async throws {
        // Check and request permission
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // Even if we request it, we might still not have it immediately.
            // ScreenCaptureKit will fail to start if we don't.
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
        }

        let contentFilter: SCContentFilter
        let configuration = SCStreamConfiguration()
        
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = false
        
        switch target {
        case .fullScreen(let display):
            contentFilter = SCContentFilter(display: display, excludingWindows: [])
            configuration.width = Int(display.width)
            configuration.height = Int(display.height)
        case .window(let window):
            contentFilter = SCContentFilter(desktopIndependentWindow: window)
            configuration.width = Int(window.frame.width)
            configuration.height = Int(window.frame.height)
        case .region(let display, let region):
            contentFilter = SCContentFilter(display: display, excludingWindows: [])
            configuration.sourceRect = region
            configuration.width = Int(region.width)
            configuration.height = Int(region.height)
        }
        
        stream = SCStream(filter: contentFilter, configuration: configuration, delegate: nil)
        
        do {
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream?.startCapture()
        } catch {
            throw CaptureError.streamStartFailed(error.localizedDescription)
        }
    }
    
    public func stopCapture() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
    
    // MARK: - SCStreamOutput
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        
        if hasMeaningfulChange(sampleBuffer) {
            frameSubject.send(sampleBuffer)
        }
    }
    
    internal func hasMeaningfulChange(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Simple average hash (very fast)
        // Divide frame into hashResolution x hashResolution grid
        let blockWidth = width / hashResolution
        let blockHeight = height / hashResolution
        var currentHash: [UInt64] = Array(repeating: 0, count: hashResolution * hashResolution)
        
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        for row in 0..<hashResolution {
            for col in 0..<hashResolution {
                var totalLuminance: UInt64 = 0
                let startY = row * blockHeight
                let startX = col * blockWidth
                
                // Sample center of each block to keep it fast
                // Actually let's sample a few points in the block
                let samplePoints = 4
                for i in 0..<samplePoints {
                    let y = startY + (i * blockHeight / samplePoints)
                    let x = startX + (i * blockWidth / samplePoints)
                    let offset = y * bytesPerRow + x * 4
                    // BGRA: Luminance approx 0.299R + 0.587G + 0.114B
                    let b = Double(ptr[offset])
                    let g = Double(ptr[offset + 1])
                    let r = Double(ptr[offset + 2])
                    totalLuminance += UInt64(0.299 * r + 0.587 * g + 0.114 * b)
                }
                currentHash[row * hashResolution + col] = totalLuminance / UInt64(samplePoints)
            }
        }
        
        guard let lastHash = self.lastHash else {
            self.lastHash = currentHash
            return true // First frame is always a change
        }
        
        var diffCount = 0
        let threshold = 10.0 // Luminance difference threshold
        
        for i in 0..<currentHash.count {
            if abs(Int64(currentHash[i]) - Int64(lastHash[i])) >= Int(threshold) {
                diffCount += 1
            }
        }
        
        self.lastHash = currentHash
        
        let changePercentage = Double(diffCount) / Double(hashResolution * hashResolution)
        return changePercentage >= changeThreshold
    }
}

import XCTest
import CoreMedia
import CoreVideo
@testable import SDD

final class ScreenCaptureTests: XCTestCase {
    var screenCapture: ScreenCapture!
    
    override func setUp() {
        super.setUp()
        screenCapture = ScreenCapture()
        screenCapture.changeThreshold = 0.05
    }
    
    func createSampleBuffer(width: Int, height: Int, color: UInt8) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress?.assumingMemoryBound(to: UInt8.self)
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                ptr?[offset] = color     // B
                ptr?[offset + 1] = color // G
                ptr?[offset + 2] = color // R
                ptr?[offset + 3] = 255   // A
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription!, sampleTiming: &timingInfo, sampleBufferOut: &sampleBuffer)
        
        return sampleBuffer
    }
    
    func testChangeDetection_StaticFrames() {
        let width = 64
        let height = 64
        let frame = createSampleBuffer(width: width, height: height, color: 128)!
        
        // Initial frame should always be a "change" (to start things off)
        XCTAssertTrue(screenCapture.hasMeaningfulChange(frame))
        
        // Next 10 frames are identical
        for _ in 0..<10 {
            XCTAssertFalse(screenCapture.hasMeaningfulChange(frame))
        }
    }
    
    func testChangeDetection_ChangedFrames() {
        let width = 64
        let height = 64
        
        // Initial frame
        let initialFrame = createSampleBuffer(width: width, height: height, color: 0)!
        _ = screenCapture.hasMeaningfulChange(initialFrame)
        
        // 10 changed frames
        for i in 1...10 {
            let changedFrame = createSampleBuffer(width: width, height: height, color: UInt8(i * 10))!
            XCTAssertTrue(screenCapture.hasMeaningfulChange(changedFrame), "Frame \(i) should be detected as change")
        }
    }
}

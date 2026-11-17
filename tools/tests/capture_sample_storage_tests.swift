import CoreMedia
import CoreVideo
import Foundation

@main enum CaptureSampleStorageTests {
    static func main() throws {
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let source = pixel!
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(source, plane), plane == 0 ? 37 : 129,
                   CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane))
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        CVBufferSetAttachment(source, "test_pixel" as CFString, "original" as CFString, .shouldPropagate)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: source,
                                                                 formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 240),
            presentationTimeStamp: CMTime(value: 123456789, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: source,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        CMSetAttachment(sample!, key: "test_sample" as CFString, value: "metadata" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let detached = try CaptureSampleStorage().copy(sample!)
        precondition(CMSampleBufferGetPresentationTimeStamp(detached) == timing.presentationTimeStamp)
        precondition(CMSampleBufferGetDuration(detached) == timing.duration)
        let result = CMSampleBufferGetImageBuffer(detached)!
        precondition(result !== source)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(source, 0), 0, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * 16)
        CVPixelBufferUnlockBaseAddress(source, [])
        CVPixelBufferLockBaseAddress(result, .readOnly)
        precondition(CVPixelBufferGetBaseAddressOfPlane(result, 0)!.load(as: UInt8.self) == 37)
        precondition(CVPixelBufferGetBaseAddressOfPlane(result, 1)!.load(as: UInt8.self) == 129)
        CVPixelBufferUnlockBaseAddress(result, .readOnly)
        precondition(CMGetAttachment(detached, key: "test_sample" as CFString, attachmentModeOut: nil) as? String == "metadata")
        print("PASS: detached video planes, original timestamps, duration and sample metadata")
    }
}

import Foundation
import VideoToolbox
import CoreMedia

/// A prepared real-time SDK encoder. Original capture timestamps are preserved;
/// AVAssetWriter receives compressed packets instead of owning camera buffers.
final class RealtimeVideoEncoder {
    enum Failure: LocalizedError {
        case operation(String, OSStatus)
        var errorDescription: String? {
            switch self { case let .operation(name, status): return "Video encoder \(name) failed (\(status))." }
        }
    }
    private final class Frame {
        let completion: (OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void
        init(_ completion: @escaping (OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void) { self.completion = completion }
    }
    private let session: VTCompressionSession
    let hardwareAccelerated: Bool
    var pixelBufferPool: CVPixelBufferPool? { VTCompressionSessionGetPixelBufferPool(session) }
    var pendingFrameCount: Int? {
        var pointer: UnsafeRawPointer?
        guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_NumberOfPendingFrames, allocator: nil, valueOut: &pointer) == noErr,
              let pointer else { return nil }
        return (Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue() as? NSNumber)?.intValue
    }
    var diagnosticProperties: [String: Any] {
        var result: [String: Any] = [:]
        for key in [kVTCompressionPropertyKey_RealTime, kVTCompressionPropertyKey_ExpectedFrameRate,
                    kVTCompressionPropertyKey_NumberOfPendingFrames, kVTCompressionPropertyKey_AverageBitRate,
                    kVTCompressionPropertyKey_ProfileLevel, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] {
            var pointer: UnsafeRawPointer?
            if VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &pointer) == noErr, let pointer {
                let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue()
                result[key as String] = (value as? NSNumber).map { $0 as Any } ?? String(describing: value)
            }
        }
        return result
    }

    static func hardwareSpecification(codec: CMVideoCodecType) -> [CFString: Any]? {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]],
              let identifier = encoders.first(where: {
                  ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec &&
                  ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
              })?[kVTVideoEncoderList_EncoderID as String] as? String else { return nil }
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EncoderID: identifier]
        if #available(iOS 17.4, macOS 10.9, *) { specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        return specification
    }

    init(width: Int, height: Int, codec: CMVideoCodecType, framesPerSecond: Double, bitRate: Int) throws {
        var created: VTCompressionSession?
        guard let specification = Self.hardwareSpecification(codec: codec) else { throw Failure.operation("hardware availability", kVTCouldNotFindVideoEncoderErr) }
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: codec, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: { _, source, status, flags, sample in
                guard let source else { return }
                let frame = Unmanaged<Frame>.fromOpaque(source).takeRetainedValue()
                frame.completion(status, flags, sample)
            }, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw Failure.operation("creation", status) }
        session = created
        do {
            func set(_ key: CFString, _ value: CFTypeRef) throws {
                let status = VTSessionSetProperty(created, key: key, value: value)
                guard status == noErr else { throw Failure.operation(key as String, status) }
            }
            try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber)
            try set(kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber)
            if #available(iOS 18.0, macOS 15.0, *) {
                let rateStatus = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaximumRealTimeFrameRate,
                                                     value: framesPerSecond as CFNumber)
                if rateStatus != noErr && rateStatus != kVTPropertyNotSupportedErr { throw Failure.operation("maximum real-time rate", rateStatus) }
            }
            // Optional optimization; capability support is queried by its status.
            _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            let prepare = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepare == noErr else { throw Failure.operation("preparation", prepare) }
            if #available(iOS 17.4, macOS 10.9, *) {
                var hardwarePointer: UnsafeRawPointer?
                let hardwareStatus = VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                                           allocator: nil, valueOut: &hardwarePointer)
                let hardware = hardwarePointer.map { Unmanaged<CFTypeRef>.fromOpaque($0).takeRetainedValue() }
                guard hardwareStatus == noErr, (hardware as? Bool) == true else { throw Failure.operation("hardware verification", hardwareStatus) }
            }
            hardwareAccelerated = true
        } catch { VTCompressionSessionInvalidate(created); throw error }
    }

    func encode(_ sample: CMSampleBuffer, completion: @escaping (OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void) throws {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { throw Failure.operation("pixel buffer", -1) }
        let frame = Unmanaged.passRetained(Frame(completion))
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), duration: CMSampleBufferGetDuration(sample),
            frameProperties: nil, sourceFrameRefcon: frame.toOpaque(), infoFlagsOut: nil)
        guard status == noErr else { frame.release(); throw Failure.operation("submission", status) }
    }
    func complete() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw Failure.operation("drain", status) }
    }
    deinit { VTCompressionSessionInvalidate(session) }
}

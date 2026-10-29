import UIKit
import AVFoundation
import CoreLocation
import CoreMotion
import CoreVideo
import ImageIO
import StoreKit
import os.log
import simd
import UniformTypeIdentifiers
import ARKit
import VideoToolbox

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}

private extension UILabel {
    var letterSpacing: CGFloat {
        get { 0 }
        set {
            guard let text = text else { return }
            attributedText = NSAttributedString(
                string: text,
                attributes: [.kern: newValue]
            )
        }
    }
}

private extension UIView {
    func subviewsRecursive() -> [UIView] {
        subviews + subviews.flatMap { $0.subviewsRecursive() }
    }
}

private final class PurchaseManager {
    static let shared = PurchaseManager()
    static let premiumProductID = "com.grape.SensorRecorder.unlimited"

    enum PurchaseOutcome {
        case purchased
        case pending
        case cancelled
    }

    private let premiumCacheKey = "sensor_recorder.premium_unlocked"
    private var premiumProduct: Product?
    private var transactionUpdatesTask: Task<Void, Never>?

    var isPremiumUnlocked: Bool {
        UserDefaults.standard.bool(forKey: premiumCacheKey)
    }

    var premiumDisplayPrice: String? {
        premiumProduct?.displayPrice
    }

    private init() {}

    func start() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                if case .verified(let transaction) = result,
                   transaction.productID == Self.premiumProductID {
                    self.setPremiumUnlocked(transaction.revocationDate == nil)
                    await transaction.finish()
                }
            }
        }

        Task {
            _ = try? await loadPremiumProduct()
            await refreshEntitlements()
        }
    }

    func stop() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = nil
    }

    @discardableResult
    func loadPremiumProduct() async throws -> Product? {
        if let premiumProduct {
            return premiumProduct
        }
        let products = try await Product.products(for: [Self.premiumProductID])
        premiumProduct = products.first(where: { $0.id == Self.premiumProductID })
        return premiumProduct
    }

    func purchasePremium() async throws -> PurchaseOutcome {
        guard let product = try await loadPremiumProduct() else {
            throw PurchaseError.productUnavailable
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verifiedTransaction(from: verification)
            setPremiumUnlocked(transaction.revocationDate == nil)
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restorePurchases() async throws -> Bool {
        try await AppStore.sync()
        await refreshEntitlements()
        return isPremiumUnlocked
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.premiumProductID,
                  transaction.revocationDate == nil else {
                continue
            }
            unlocked = true
        }
        setPremiumUnlocked(unlocked)
    }

    private func verifiedTransaction(
        from result: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw PurchaseError.unverifiedTransaction
        }
    }

    private func setPremiumUnlocked(_ unlocked: Bool) {
        UserDefaults.standard.set(unlocked, forKey: premiumCacheKey)
    }

    enum PurchaseError: LocalizedError {
        case productUnavailable
        case unverifiedTransaction

        var errorDescription: String? {
            switch self {
            case .productUnavailable:
                return "The upgrade product is not available yet. Please check the App Store configuration."
            case .unverifiedTransaction:
                return "The App Store could not verify this purchase."
            }
        }
    }
}

private final class PortraitSettingsViewController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

private final class CameraStreamRecorder {
    fileprivate static let videoMediaTimeScale: CMTimeScale = 1_000_000
    private static let resolutionSupportLock = NSLock()
    private static var resolutionSupport: [String: Bool] = [:]

    private struct PendingFrame {
        let presentationTime: CMTime
        let width: Int
        let height: Int
        let intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float)?
        var encodedBuffer: CMSampleBuffer? = nil
        var packetLease: PacketLease? = nil
        let sensorSec: TimeInterval
        let exposureSec: Double
        let iso: Float
        let sequence: Int64
    }
    private final class PacketLease {
        let semaphore: DispatchSemaphore
        init(_ semaphore: DispatchSemaphore) { self.semaphore = semaphore }
        deinit { semaphore.signal() }
    }
    private let writerQueue: DispatchQueue
    private let encodingQueue: DispatchQueue
    private let writerQueueKey = DispatchSpecificKey<Bool>()
    private var encoderFinishing = false
    private let captureStorage = CaptureSampleStorage()
    private let encodedPacketSlots = DispatchSemaphore(value: 64)
    private var realtimeEncoder: RealtimeVideoEncoder?
    private var encodingFrames = 0
    private var movieOrigin: CMTime?
    private var inFlightFrames = DispatchSemaphore(value: 6)
    var onFailure: ((String) -> Void)? {
        didSet { if let failureMessage { onFailure?(failureMessage) } }
    }
    private var failureMessage: String?
    var expectedResolution: String? {
        didSet {
            let dimensions = expectedResolution?.split(separator: "x").compactMap { Int($0) } ?? []
            if dimensions.count == 2 {
                let estimatedBytes = max(1, dimensions[0] * dimensions[1] * 3 / 2)
                inFlightFrames = DispatchSemaphore(value: max(6, min(64, 128 * 1024 * 1024 / estimatedBytes)))
                // Encoder preparation must not hold the first capture sample
                // while subsequent camera callbacks consume the capture pool.
                writerQueue.sync { prepareEncoder(width: dimensions[0], height: dimensions[1]) }
            }
        }
    }
    private var hasReportedFailure = false
    private var receivedFrames: Int64 = 0
    private var pendingFrames: [PendingFrame] = []
    private var drainRequested = false
    private var finishCallbacks: [() -> Void] = []
    private var didFinish = false
    private var finalizing = false

    private let videoURL: URL
    private let infoURL: URL
    private let cameraName: String
    private let includeAudioTrack: Bool
    private let targetFrameRate: Double
    private let captureFrameRate: Double
    private let hardwareSynchronized: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var infoHandle: FileHandle?
    private var firstPTS: CMTime?
    private let utcMinusSensorOffsetSec: TimeInterval
    private var videoCodec: AVVideoCodecType = .h264
    private var frameIndex = 0
    private var isFinishing = false
    private var didWriteCSVHeader = false

    init(
        cameraName: String,
        videoURL: URL,
        infoURL: URL,
        includeAudioTrack: Bool,
        targetFrameRate: Double,
        captureFrameRate: Double,
        hardwareSynchronized: Bool = false
    ) {
        self.cameraName = cameraName
        self.writerQueue = DispatchQueue(label: "com.sensorrecorder.writer.\(cameraName)", autoreleaseFrequency: .workItem)
        self.encodingQueue = DispatchQueue(label: "com.sensorrecorder.encoder.\(cameraName)", qos: .userInitiated, autoreleaseFrequency: .workItem)
        self.videoURL = videoURL
        self.infoURL = infoURL
        self.includeAudioTrack = includeAudioTrack
        self.targetFrameRate = targetFrameRate
        self.captureFrameRate = captureFrameRate
        self.hardwareSynchronized = hardwareSynchronized
        self.writerQueue.setSpecific(key: writerQueueKey, value: true)
        self.utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: infoURL)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("# camera,\(cameraName)")
    }

    func append(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice?, sessionClock: CMClock?, recordSlot: Int64? = nil, sessionOrigin: CMTime? = nil, sensorSec: TimeInterval? = nil) {
        // Clock correlation can change while audio runs. Convert at admission,
        // once, rather than again after asynchronous encoding and disk writes.
        let capturedSensorSec = sensorSec ?? CMTimeGetSeconds(captureSensorTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), sessionClock: sessionClock))
        guard inFlightFrames.wait(timeout: .now()) == .success else {
            let pending = realtimeEncoder?.pendingFrameCount
            writerQueue.async { self.fail("Capture-to-writer queue overflow; SDK pending frames: \(pending.map(String.init) ?? "unknown")") }
            return
        }
        let exposureSec = device.map { CMTimeGetSeconds($0.exposureDuration) } ?? .nan
        let iso = device?.iso ?? .nan
        let detached: CMSampleBuffer
        do { detached = try captureStorage.copy(sampleBuffer) }
        catch {
            inFlightFrames.signal()
            let pending = realtimeEncoder?.pendingFrameCount
            writerQueue.async { self.fail(error.localizedDescription + "; SDK pending frames: \(pending.map(String.init) ?? "unknown")") }
            return
        }
        encodingQueue.async {
            defer { self.inFlightFrames.signal() }
            self.appendOnWriterQueue(detached, sensorSec: capturedSensorSec, exposureSec: exposureSec, iso: iso, recordSlot: recordSlot, sessionOrigin: sessionOrigin)
        }
    }

    private func appendOnWriterQueue(_ sampleBuffer: CMSampleBuffer, sensorSec: TimeInterval, exposureSec: Double, iso: Float, recordSlot: Int64?, sessionOrigin: CMTime?) {
        guard !encoderFinishing else { return }
        guard infoHandle != nil else { fail("Cannot open the video index file"); return }
        if let image = CMSampleBufferGetImageBuffer(sampleBuffer), let expectedResolution,
           "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))" != expectedResolution {
            fail("The delivered pixel dimensions differ from the validated settings")
            return
        }
        let sequence = recordSlot ?? receivedFrames
        receivedFrames += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil { firstPTS = pts; movieOrigin = sessionOrigin ?? pts }
        if realtimeEncoder == nil, let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
            prepareEncoder(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        }
        guard let realtimeEncoder else { return }
        let image = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let frame = PendingFrame(presentationTime: pts, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                                 intrinsics: cameraIntrinsics(sampleBuffer), sensorSec: sensorSec,
                                 exposureSec: exposureSec, iso: iso, sequence: sequence)
        writerQueue.async { self.encodingFrames += 1 }
        do {
            try realtimeEncoder.encode(sampleBuffer) { status, flags, encoded in
                guard self.encodedPacketSlots.wait(timeout: .now()) == .success else {
                    self.writerQueue.async { self.encodingFrames -= 1; self.fail("Compressed video write queue overflow") }
                    return
                }
                let lease = PacketLease(self.encodedPacketSlots)
                self.writerQueue.async {
                    self.encodingFrames -= 1
                    guard !self.finalizing else { return }
                    guard status == noErr, !flags.contains(.frameDropped), let encoded else {
                        self.fail("The real-time encoder did not produce a captured frame (\(status))")
                        if self.isFinishing && self.encodingFrames == 0 { self.drainPendingFrames() }
                        return
                    }
                    if self.writer == nil { self.configureWriter(encoded) }
                    guard self.writer != nil else { return }
                    var ready = frame; ready.encodedBuffer = encoded; ready.packetLease = lease
                    self.pendingFrames.append(ready)
                    self.drainPendingFrames()
                }
            }
        } catch { writerQueue.async { self.encodingFrames -= 1; self.fail(error.localizedDescription) } }
    }

    private func scheduleDrainIfNeeded() {
        if !pendingFrames.isEmpty && !drainRequested {
            drainRequested = true
            writerQueue.asyncAfter(deadline: .now() + .milliseconds(5)) {
                self.drainRequested = false
                self.drainPendingFrames()
            }
        }
    }

    private func drainPendingFrames() {
        guard let writer, let input else { return }
        if writer.status == .failed || writer.status == .cancelled {
            writeInfoLine("# writer_failed \(writer.error?.localizedDescription ?? "unknown")")
            pendingFrames.removeAll()
            fail(writer.error?.localizedDescription ?? "Video writer failed")
        }
        while !pendingFrames.isEmpty && input.isReadyForMoreMediaData && writer.status == .writing {
            let frame = pendingFrames.removeFirst()
            if let encoded = frame.encodedBuffer, input.append(encoded) {
                writeInfo(frame)
                frameIndex += 1
            } else {
                writeInfoLine("# append_failed \(frame.sequence) \(writer.error?.localizedDescription ?? "unknown")")
                pendingFrames.removeAll()
                fail(writer.error?.localizedDescription ?? "Video append failed")
                break
            }
        }
        scheduleDrainIfNeeded()
        if isFinishing && pendingFrames.isEmpty && encodingFrames == 0 {
            finalizeWriter()
        }
    }

    private func fail(_ reason: String) {
        guard DispatchQueue.getSpecific(key: writerQueueKey) == true else {
            writerQueue.async { self.fail(reason) }
            return
        }
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        failureMessage = "\(cameraName): \(reason)"
        writeInfoLine("# capture_failed,\(reason)")
        onFailure?(failureMessage!)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { self.appendAudioOnWriterQueue(sampleBuffer) }
    }

    func noteSDKRecommendations(_ output: AVCaptureVideoDataOutput?) {
        guard let output else { return }
        var snapshot: [String: Any] = ["thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                                      "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
                                      "encoder_properties": realtimeEncoder?.diagnosticProperties ?? [:]]
        for codec in output.availableVideoCodecTypesForAssetWriter(writingTo: .mp4) {
            snapshot[codec.rawValue] = output.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: .mp4)
        }
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            writerQueue.async { self.writeInfoLine("# sdk_encoding_recommendations,\(text)") }
        }
    }

    private func appendAudioOnWriterQueue(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing,
              let firstPTS = firstPTS,
              let writer = writer,
              let audioInput = audioInput else {
            return
        }
        guard writer.status == .writing else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= firstPTS else { return }
        guard audioInput.isReadyForMoreMediaData else {
            fail("The embedded audio encoder could not accept a captured sample")
            return
        }
        guard audioInput.append(sampleBuffer) else {
            fail(writer.error?.localizedDescription ?? "Embedded audio append failed")
            return
        }
    }

    func finish(_ completion: @escaping () -> Void) {
        encodingQueue.async {
            if self.encoderFinishing {
                self.writerQueue.async {
                    if self.didFinish { completion() } else { self.finishCallbacks.append(completion) }
                }
                return
            }
            self.encoderFinishing = true
            do { try self.realtimeEncoder?.complete() }
            catch { self.fail(error.localizedDescription) }
            // Encoder completion has enqueued every packet. The muxer queue
            // finishes only after those packet handlers and their CSV rows.
            self.writerQueue.async {
                self.finishCallbacks.append(completion)
                self.isFinishing = true
                if self.writer == nil && self.encodingFrames == 0 { self.finalizeWriter() }
                else { self.drainPendingFrames() }
                self.writerQueue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
                    guard let self, !self.finalizing else { return }
                    self.fail("Video encoder did not finish draining")
                    self.pendingFrames.removeAll()
                    self.finalizeWriter()
                }
            }
        }
    }

    private func finalizeWriter() {
        guard !finalizing else { return }
        finalizing = true
        do { try infoHandle?.synchronize(); try infoHandle?.close() }
        catch { fail("Could not finalize the video index: \(error.localizedDescription)") }
        infoHandle = nil
        guard let writer = writer else {
            fail("No video samples were written")
            completeFinish()
            return
        }
        guard firstPTS != nil else {
            writer.cancelWriting()
            fail("No video samples were written")
            completeFinish()
            return
        }
        guard writer.status == .writing else {
            if writer.status == .failed || writer.status == .cancelled {
                fail(writer.error?.localizedDescription ?? "Video writing did not complete")
            }
            completeFinish()
            return
        }
        input?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
            self.writerQueue.async {
                if writer.status == .failed { self.fail(writer.error?.localizedDescription ?? "Video finalization failed") }
                self.completeFinish()
            }
        }
    }

    private func completeFinish() {
        didFinish = true
        let callbacks = finishCallbacks
        finishCallbacks.removeAll()
        for completion in callbacks {
            completion()
        }
    }

    func writeDeviceFormat(_ device: AVCaptureDevice?) {
        guard let device = device else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        writeInfoLine("# active_format,\(dimensions.width)x\(dimensions.height),capture_fps,\(String(format: "%.3f", captureFrameRate))")
        writeInfoLine("# recording,target_fps,\(String(format: "%.3f", targetFrameRate)),sampling,\(hardwareSynchronized ? "hardware_sync_complete_groups" : "camera_all_frames_original_timestamps")")
        writeInfoLine(hardwareSynchronized ? "# record_slot,shared_hardware_sync_group_index" : "# record_slot,camera_received_frame_sequence")
        writeInfoLine("# video_media_time_scale,\(Self.videoMediaTimeScale),units_per_second")
        writeInfoLine("# movie_media_time_scale,\(Self.videoMediaTimeScale),units_per_second")
        writeInfoLine("# exposure,mode,\(exposureModeLabel(device.exposureMode)),active_max_duration_sec,\(String(format: "%.9f", CMTimeGetSeconds(device.activeMaxExposureDuration)))")
        writeInfoLine("# focus,mode,\(focusModeLabel(device.focusMode)),lens_position,\(String(format: "%.6f", device.lensPosition))")
        writeInfoLine("# control_state_source,\(device.deviceType.rawValue),current_controller_state_not_per_frame_EXIF")
        let gains = device.deviceWhiteBalanceGains
        writeInfoLine("# white_balance,mode,\(device.whiteBalanceMode.rawValue),red,\(gains.redGain),green,\(gains.greenGain),blue,\(gains.blueGain)")
    }

    private func exposureModeLabel(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked:
            return "locked"
        case .autoExpose:
            return "auto"
        case .continuousAutoExposure:
            return "continuous_auto"
        case .custom:
            return "custom"
        @unknown default:
            return "unknown"
        }
    }

    private func focusModeLabel(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked:
            return "locked"
        case .autoFocus:
            return "auto"
        case .continuousAutoFocus:
            return "continuous_auto"
        @unknown default:
            return "unknown"
        }
    }

    private func prepareEncoder(width: Int, height: Int) {
        guard realtimeEncoder == nil else { return }
        videoCodec = Self.preferredVideoCodec(width: width, height: height)
        do {
            realtimeEncoder = try RealtimeVideoEncoder(width: width, height: height,
                codec: videoCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                framesPerSecond: targetFrameRate, bitRate: Self.videoBitRate(width: width, height: height, codec: videoCodec, framesPerSecond: targetFrameRate))
            if let pool = realtimeEncoder?.pixelBufferPool { captureStorage.useEncoderPool(pool, framesPerSecond: targetFrameRate) }
            writeInfoLine("# video,\(width)x\(height),codec,\(videoCodec.rawValue)")
            writeInfoLine("# encoder,VideoToolbox,hardware,\(realtimeEncoder?.hardwareAccelerated == true),real_time,true,frame_reordering,false")
        } catch { fail(error.localizedDescription) }
    }

    private func configureWriter(_ sampleBuffer: CMSampleBuffer) {
        do {
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            // Track precision alone is insufficient: MP4 edit-list offsets use
            // the movie timescale and must preserve constituent-stream skew.
            writer.movieTimeScale = Self.videoMediaTimeScale
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                           sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
            input.expectsMediaDataInRealTime = true
            input.mediaTimeScale = Self.videoMediaTimeScale
            guard writer.canAdd(input) else {
                writeInfoLine("# writer_input_failed")
                fail("The video encoder rejected its input settings")
                return
            }
            writer.add(input)
            if includeAudioTrack {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioOutputSettings())
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    self.audioInput = audioInput
                    writeInfoLine("# audio,aac")
                } else {
                    writeInfoLine("# audio_input_failed")
                    fail("The video writer could not attach the requested audio track")
                    return
                }
            }
            self.writer = writer
            self.input = input
            if !writer.startWriting() { fail(writer.error?.localizedDescription ?? "Video writer preparation failed") }
            writer.startSession(atSourceTime: movieOrigin ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            writeCSVHeaderIfNeeded()
        } catch {
            writeInfoLine("# writer_init_failed \(error.localizedDescription)")
            fail(error.localizedDescription)
        }
    }

    fileprivate static func canEncodeMP4(width: Int, height: Int) -> Bool {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor_recorder_probe_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
            let settings = videoOutputSettings(width: width, height: height)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            return writer.canApply(outputSettings: settings, forMediaType: .video) && writer.canAdd(input)
        } catch {
            return false
        }
    }

    fileprivate static func isRecordableMP4Resolution(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let key = "\(width)x\(height)"
        resolutionSupportLock.lock()
        defer { resolutionSupportLock.unlock() }
        if let supported = resolutionSupport[key] { return supported }
        let supported = canEncodeMP4(width: width, height: height)
        resolutionSupport[key] = supported
        return supported
    }

    fileprivate static func preferredVideoCodec(width: Int, height: Int) -> AVVideoCodecType {
        for (type, codec) in [(kCMVideoCodecType_HEVC, AVVideoCodecType.hevc), (kCMVideoCodecType_H264, .h264)] {
            guard let specification = RealtimeVideoEncoder.hardwareSpecification(codec: type) else { continue }
            var properties: CFDictionary?
            if VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height), codecType: type,
                    encoderSpecification: specification as CFDictionary, encoderIDOut: nil,
                    supportedPropertiesOut: &properties) == noErr { return codec }
        }
        return .h264
    }

    fileprivate static func videoOutputSettings(width: Int, height: Int) -> [String: Any] {
        let codec = preferredVideoCodec(width: width, height: height)
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitRate(width: width, height: height, codec: codec),
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }

    fileprivate static func videoBitRate(width: Int, height: Int, codec: AVVideoCodecType, framesPerSecond: Double = 30) -> Int {
        let pixels = width * height
        let bitsPerPixel = codec == .hevc ? 3 : 4
        return max(Int(Double(pixels * bitsPerPixel) * max(framesPerSecond, 30) / 30), 2_000_000)
    }

    private static func audioOutputSettings() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
        let channelCount = max(session.inputNumberOfChannels, 1)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 128_000
        ]
    }

    private func writeInfo(_ frame: PendingFrame) {
        writeCSVHeaderIfNeeded()
        let sensorSec = frame.sensorSec
        let utcSec = sensorSec + utcMinusSensorOffsetSec
        writeInfoLine(String(
            format: "%d,%lld,%.6f,%.6f,%.9f,%.3f,%d,%d,%.9f,%.9f,%.9f,%.9f,%.9f",
            frameIndex, frame.sequence, sensorSec, utcSec, frame.exposureSec, frame.iso, frame.width, frame.height,
            frame.intrinsics?.fx ?? .nan, frame.intrinsics?.fy ?? .nan, frame.intrinsics?.cx ?? .nan, frame.intrinsics?.cy ?? .nan,
            CMTimeGetSeconds(frame.presentationTime)
        ))
    }

    private func captureSensorTime(for presentationTime: CMTime, sessionClock: CMClock?) -> CMTime {
        guard let sessionClock = sessionClock else {
            return presentationTime
        }
        return CMSyncConvertTime(presentationTime, from: sessionClock, to: CMClockGetHostTimeClock())
    }

    private func cameraIntrinsics(_ sampleBuffer: CMSampleBuffer) -> (fx: Float, fy: Float, cx: Float, cy: Float)? {
        guard let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) else {
            return nil
        }
        let data = attachment as! CFData
        guard CFDataGetLength(data) >= MemoryLayout<matrix_float3x3>.size else {
            return nil
        }
        let matrix = CFDataGetBytePtr(data).withMemoryRebound(to: matrix_float3x3.self, capacity: 1) { $0.pointee }
        return (
            fx: matrix.columns.0.x,
            fy: matrix.columns.1.y,
            cx: matrix.columns.2.x,
            cy: matrix.columns.2.y
        )
    }

    private func writeInfoLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8), let infoHandle else { return }
        do { try infoHandle.write(contentsOf: data) }
        catch {
            if !hasReportedFailure {
                hasReportedFailure = true
                failureMessage = "\(cameraName): video index write failed: \(error.localizedDescription)"
                onFailure?(failureMessage!)
            }
        }
    }

    private func writeCSVHeaderIfNeeded() {
        guard !didWriteCSVHeader else { return }
        didWriteCSVHeader = true
        writeInfoLine("# capture_pts_sec,original_session_synchronization_clock_before_host_clock_conversion")
        writeInfoLine("frame_index,record_slot,sensor_sec,utc_sec,exposure_sec,iso,width_px,height_px,fx_px,fy_px,cx_px,cy_px,capture_pts_sec")
    }
}

private final class ARKitFrameRecorder {
    private let videoURL: URL
    private let infoURL: URL
    private let targetFrameRate: Double
    private let captureFrameRate: Double
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var infoHandle: FileHandle?
    private var firstPTS: CMTime?
    private let utcMinusSensorOffsetSec: TimeInterval
    private var videoCodec: AVVideoCodecType = .h264
    private var frameIndex = 0
    private var isFinishing = false
    private var didWriteCSVHeader = false
    private var previousQuaternionXYZW: SIMD4<Float>?

    init(videoURL: URL, infoURL: URL, targetFrameRate: Double, captureFrameRate: Double) {
        self.videoURL = videoURL
        self.infoURL = infoURL
        self.targetFrameRate = targetFrameRate
        self.captureFrameRate = captureFrameRate
        self.utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: infoURL)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("# camera,arkit")
        writeInfoLine("# pixel_orientation,arkit_native_landscape,device_orientation,landscape_right")
        writeInfoLine("# camera_coordinates,opencv_rdf,x_right,y_down,z_forward")
        writeInfoLine("# pose_convention,T_world_camera,parent_from_child,world_coordinates,arkit_gravity")
    }

    func append(
        pixelBuffer sourcePixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        camera: ARCamera,
        recordSlot: Int64
    ) {
        guard !isFinishing else { return }
        if writer == nil {
            configureWriter(pixelBuffer: sourcePixelBuffer)
        }
        guard let writer = writer, let input = input else { return }

        if firstPTS == nil {
            firstPTS = presentationTime
            writer.startWriting()
            writer.startSession(atSourceTime: presentationTime)
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else {
            if writer.status == .failed {
                writeInfoLine("# writer_failed \(writer.error?.localizedDescription ?? "unknown")")
            }
            return
        }

        let sampleBuffer = makeSampleBuffer(pixelBuffer: sourcePixelBuffer, presentationTime: presentationTime)
        guard let sampleBuffer = sampleBuffer else {
            writeInfoLine("# sample_buffer_failed \(frameIndex)")
            return
        }

        guard input.append(sampleBuffer) else {
            writeInfoLine("# append_failed \(frameIndex) \(writer.error?.localizedDescription ?? "unknown")")
            return
        }

        writeInfo(
            presentationTime: presentationTime,
            camera: camera,
            pixelBuffer: sourcePixelBuffer,
            recordSlot: recordSlot
        )
        frameIndex += 1
    }

    func finish(_ completion: @escaping () -> Void) {
        guard !isFinishing else {
            completion()
            return
        }
        isFinishing = true
        infoHandle?.synchronizeFile()
        infoHandle?.closeFile()
        infoHandle = nil

        guard let writer = writer else {
            completion()
            return
        }
        input?.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    func writeDeviceFormat(resolution: CGSize) {
        writeInfoLine("# active_format,\(Int(resolution.width))x\(Int(resolution.height)),capture_fps,\(String(format: "%.3f", captureFrameRate))")
        writeInfoLine("# recording,target_fps,\(String(format: "%.3f", targetFrameRate)),sampling,host_time_grid")
        writeInfoLine("# video_media_time_scale,\(CameraStreamRecorder.videoMediaTimeScale),units_per_second")
    }

    var codecName: String {
        videoCodec.rawValue
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription = formatDescription else {
            return nil
        }

        let durationTimescale = CMTimeScale(max(captureFrameRate.rounded(), 1))
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: durationTimescale),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private func configureWriter(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        do {
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            let settings = CameraStreamRecorder.videoOutputSettings(width: width, height: height)
            let codec = settings[AVVideoCodecKey] as? AVVideoCodecType ?? .h264
            videoCodec = codec
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.mediaTimeScale = CameraStreamRecorder.videoMediaTimeScale
            guard writer.canApply(outputSettings: settings, forMediaType: .video),
                  writer.canAdd(input) else {
                writeInfoLine("# writer_input_failed")
                return
            }
            writer.add(input)
            self.writer = writer
            self.input = input
            writeInfoLine("# video,\(width)x\(height),codec,\(codec.rawValue)")
            writeCSVHeaderIfNeeded()
        } catch {
            writeInfoLine("# writer_init_failed \(error.localizedDescription)")
        }
    }

    private func writeInfo(
        presentationTime: CMTime,
        camera: ARCamera,
        pixelBuffer: CVPixelBuffer,
        recordSlot: Int64
    ) {
        writeCSVHeaderIfNeeded()
        let sensorTime = CMSyncConvertTime(presentationTime, from: CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock())
        let sensorSec = CMTimeGetSeconds(sensorTime)
        let utcSec = sensorSec + utcMinusSensorOffsetSec

        // Keep capturedImage and camera.intrinsics in ARKit's native pixel layout.
        // Only convert camera axes from ARKit (x right, y up, z back) to OpenCV RDF.
        var arkitToOpenCV = matrix_identity_float4x4
        arkitToOpenCV.columns.0.x = 1
        arkitToOpenCV.columns.1.y = -1
        arkitToOpenCV.columns.2.z = -1
        let transform = simd_mul(camera.transform, arkitToOpenCV)
        let tx = transform.columns.3.x
        let ty = transform.columns.3.y
        let tz = transform.columns.3.z
        var (qw, qx, qy, qz) = quaternionFromRotationMatrix(transform)
        var quaternionXYZW = SIMD4<Float>(qx, qy, qz, qw)
        if let previousQuaternionXYZW,
           simd_dot(previousQuaternionXYZW, quaternionXYZW) < 0 {
            quaternionXYZW = -quaternionXYZW
            qx = quaternionXYZW.x
            qy = quaternionXYZW.y
            qz = quaternionXYZW.z
            qw = quaternionXYZW.w
        }
        previousQuaternionXYZW = quaternionXYZW

        let intrinsics = camera.intrinsics
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        let exposureSec = camera.exposureDuration
        let trackingLabel = trackingStateLabel(camera.trackingState)

        writeInfoLine(String(
            format: "%d,%lld,%.6f,%.6f,%.9f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%@,%.9f,%.9f,%.9f,%.9f,%d,%d",
            frameIndex, recordSlot, sensorSec, utcSec,
            tx, ty, tz, qw, qx, qy, qz,
            Float(exposureSec),
            trackingLabel,
            fx, fy, cx, cy,
            width, height
        ))
    }

    private func writeInfoLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        infoHandle?.write(data)
    }

    private func writeCSVHeaderIfNeeded() {
        guard !didWriteCSVHeader else { return }
        didWriteCSVHeader = true
        writeInfoLine("frame_index,record_slot,sensor_sec,utc_sec,tx_m,ty_m,tz_m,qw,qx,qy,qz,exposure_sec,tracking_state,fx_px,fy_px,cx_px,cy_px,width_px,height_px")
    }

    private func trackingStateLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable: return "not_available"
        case .limited: return "limited"
        case .normal: return "normal"
        }
    }

    private func quaternionFromRotationMatrix(_ m: simd_float4x4) -> (Float, Float, Float, Float) {
        let rot = simd_float3x3(
            simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        let trace = rot.columns.0.x + rot.columns.1.y + rot.columns.2.z
        let qw: Float, qx: Float, qy: Float, qz: Float
        if trace > 0 {
            let s = 0.5 / sqrtf(trace + 1.0)
            qw = 0.25 / s
            qx = (rot.columns.1.z - rot.columns.2.y) * s
            qy = (rot.columns.2.x - rot.columns.0.z) * s
            qz = (rot.columns.0.y - rot.columns.1.x) * s
        } else if rot.columns.0.x > rot.columns.1.y && rot.columns.0.x > rot.columns.2.z {
            let s = 2.0 * sqrtf(1.0 + rot.columns.0.x - rot.columns.1.y - rot.columns.2.z)
            qw = (rot.columns.1.z - rot.columns.2.y) / s
            qx = 0.25 * s
            qy = (rot.columns.1.x + rot.columns.0.y) / s
            qz = (rot.columns.2.x + rot.columns.0.z) / s
        } else if rot.columns.1.y > rot.columns.2.z {
            let s = 2.0 * sqrtf(1.0 + rot.columns.1.y - rot.columns.0.x - rot.columns.2.z)
            qw = (rot.columns.2.x - rot.columns.0.z) / s
            qx = (rot.columns.1.x + rot.columns.0.y) / s
            qy = 0.25 * s
            qz = (rot.columns.2.y + rot.columns.1.z) / s
        } else {
            let s = 2.0 * sqrtf(1.0 + rot.columns.2.z - rot.columns.0.x - rot.columns.1.y)
            qw = (rot.columns.0.y - rot.columns.1.x) / s
            qx = (rot.columns.2.x + rot.columns.0.z) / s
            qy = (rot.columns.2.y + rot.columns.1.z) / s
            qz = 0.25 * s
        }
        return (qw, qx, qy, qz)
    }
}

private final class LiDARDepthStreamRecorder {
    private let depthDirectoryURL: URL
    private let infoURL: URL
    private var infoHandle: FileHandle?
    private let utcMinusSensorOffsetSec: TimeInterval
    private var frameIndex = 0

    init(outputDirectory: URL) {
        depthDirectoryURL = outputDirectory.appendingPathComponent("lidar_depth", isDirectory: true)
        infoURL = outputDirectory.appendingPathComponent("lidar_depth_info.csv")
        utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: depthDirectoryURL)
        try? FileManager.default.removeItem(at: infoURL)
        try? FileManager.default.createDirectory(at: depthDirectoryURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("frame_index,sensor_sec,utc_sec,file_name,width_px,height_px,pixel_format,bytes_per_pixel,depth_unit,depth_scale,min_depth_m,max_depth_m,fx_px,fy_px,cx_px,cy_px")
    }

    func append(depthData: AVDepthData, sensorSec: TimeInterval) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let pixelBuffer = converted.depthDataMap
        appendFloat32DepthMap(pixelBuffer, calibration: converted.cameraCalibrationData, sensorSec: sensorSec)
    }

    /// Accept a raw float32 depth map (meters) from ARKit's ARDepthData.
    func appendARKitDepthMap(
        _ pixelBuffer: CVPixelBuffer,
        intrinsics: simd_float3x3,
        imageResolution: CGSize,
        sensorSec: TimeInterval
    ) {
        appendFloat32DepthMap(
            pixelBuffer,
            arkitIntrinsics: intrinsics,
            imageResolution: imageResolution,
            sensorSec: sensorSec
        )
    }

    private func appendFloat32DepthMap(_ pixelBuffer: CVPixelBuffer, calibration: AVCameraCalibrationData?, sensorSec: TimeInterval) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float)
        if let calibration = calibration {
            intrinsics = scaledDepthIntrinsics(calibration: calibration, width: width, height: height)
        } else {
            intrinsics = (.nan, .nan, .nan, .nan)
        }
        writeDepthFrame(pixelBuffer, width: width, height: height, intrinsics: intrinsics, sensorSec: sensorSec)
    }

    private func appendFloat32DepthMap(
        _ pixelBuffer: CVPixelBuffer,
        arkitIntrinsics: simd_float3x3,
        imageResolution: CGSize,
        sensorSec: TimeInterval
    ) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let scaleX = Float(width) / Float(max(imageResolution.width, 1))
        let scaleY = Float(height) / Float(max(imageResolution.height, 1))
        let fx = arkitIntrinsics.columns.0.x * scaleX
        let fy = arkitIntrinsics.columns.1.y * scaleY
        let cx = arkitIntrinsics.columns.2.x * scaleX
        let cy = arkitIntrinsics.columns.2.y * scaleY
        writeDepthFrame(
            pixelBuffer,
            width: width,
            height: height,
            intrinsics: (fx, fy, cx, cy),
            sensorSec: sensorSec
        )
    }

    private func writeDepthFrame(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float),
        sensorSec: TimeInterval
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = MemoryLayout<UInt16>.size
        let depthScale: Float = 1000
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var depthMillimeters = [UInt16](repeating: 0, count: width * height)
        var minDepth = Float.greatestFiniteMagnitude
        var maxDepth: Float = 0
        for row in 0..<height {
            let rowBase = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for column in 0..<width {
                let value = rowBase[column]
                if value.isFinite && value > 0 {
                    minDepth = min(minDepth, value)
                    maxDepth = max(maxDepth, value)
                    depthMillimeters[row * width + column] = UInt16(min(max((value * depthScale).rounded(), 0), Float(UInt16.max)))
                }
            }
        }
        if minDepth == Float.greatestFiniteMagnitude {
            minDepth = .nan
            maxDepth = .nan
        }

        frameIndex += 1
        let fileName = String(format: "depth_%06d.png", frameIndex)
        let fileURL = depthDirectoryURL.appendingPathComponent(fileName)
        writeDepthPNG(depthMillimeters, width: width, height: height, to: fileURL)

        let utcSec = sensorSec + utcMinusSensorOffsetSec
        writeInfoLine([
            "\(frameIndex)",
            String(format: "%.9f", sensorSec),
            String(format: "%.9f", utcSec),
            fileName,
            "\(width)",
            "\(height)",
            "DepthUInt16",
            "\(bytesPerPixel)",
            "millimeter",
            String(format: "%.1f", depthScale),
            String(format: "%.6f", minDepth),
            String(format: "%.6f", maxDepth),
            String(format: "%.6f", intrinsics.fx),
            String(format: "%.6f", intrinsics.fy),
            String(format: "%.6f", intrinsics.cx),
            String(format: "%.6f", intrinsics.cy)
        ].joined(separator: ","))
    }

    private func writeDepthPNG(_ values: [UInt16], width: Int, height: Int, to url: URL) {
        let data = Data(bytes: values, count: values.count * MemoryLayout<UInt16>.size)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * MemoryLayout<UInt16>.size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func scaledDepthIntrinsics(
        calibration: AVCameraCalibrationData?,
        width: Int,
        height: Int
    ) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        guard let calibration else {
            return (.nan, .nan, .nan, .nan)
        }
        let intrinsics = calibration.intrinsicMatrix
        let reference = calibration.intrinsicMatrixReferenceDimensions
        let scaleX = reference.width > 0 ? Float(width) / Float(reference.width) : 1
        let scaleY = reference.height > 0 ? Float(height) / Float(reference.height) : 1
        return (
            fx: intrinsics.columns.0.x * scaleX,
            fy: intrinsics.columns.1.y * scaleY,
            cx: intrinsics.columns.2.x * scaleX,
            cy: intrinsics.columns.2.y * scaleY
        )
    }

    func finish() {
        infoHandle?.synchronizeFile()
        infoHandle?.closeFile()
        infoHandle = nil
    }

    private func writeInfoLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        infoHandle?.write(data)
    }
}

private final class AudioStreamRecorder {
    var onFailure: ((String) -> Void)? {
        didSet { if let failureMessage { onFailure?(failureMessage) } }
    }
    private var failureMessage: String?
    private let audioURL: URL
    private let infoURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var infoHandle: FileHandle?
    private let utcMinusSensorOffsetSec: TimeInterval
    private let statusLock = NSLock()
    private var frameIndex = 0
    private var isFinishing = false
    private var firstSensorSec: TimeInterval?
    private var latestSensorSec: TimeInterval?
    private var latestSampleRate: Double?

    init(audioURL: URL, infoURL: URL) {
        self.audioURL = audioURL
        self.infoURL = infoURL
        utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: infoURL)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("# audio,aac,m4a")
        writeInfoLine("frame_index,sensor_sec,utc_sec,duration_sec,sample_count,sample_rate_hz,channels")
    }

    func append(_ sampleBuffer: CMSampleBuffer, sessionClock: CMClock?) {
        guard !isFinishing else { return }
        guard infoHandle != nil else { fail("Cannot open the audio index file"); return }
        if writer == nil {
            configureWriter(sampleBuffer)
        }
        guard let writer = writer, let input = input else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }

        if writer.status == .writing && input.isReadyForMoreMediaData {
            guard input.append(sampleBuffer) else {
                fail(writer.error?.localizedDescription ?? "Audio append failed")
                return
            }
            let sensorSec = writeInfo(sampleBuffer, sessionClock: sessionClock)
            recordSample(sensorSec)
            frameIndex += 1
        } else {
            fail(writer.error?.localizedDescription ?? "The audio encoder could not accept a captured sample")
        }
    }

    func finish(_ completion: @escaping () -> Void) {
        guard !isFinishing else {
            completion()
            return
        }
        isFinishing = true
        do { try infoHandle?.synchronize(); try infoHandle?.close() }
        catch { fail("Could not finalize the audio index: \(error.localizedDescription)") }
        infoHandle = nil

        guard let writer = writer else {
            fail("No audio samples were written")
            completion()
            return
        }
        input?.markAsFinished()
        guard writer.status == .writing else {
            fail(writer.error?.localizedDescription ?? "Audio writing did not complete")
            completion()
            return
        }
        writer.finishWriting {
            if writer.status != .completed { self.fail(writer.error?.localizedDescription ?? "Audio finalization failed") }
            completion()
        }
    }

    func statusText() -> String {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard frameIndex > 0 else { return "AUD --" }
        return "AUD \(audioFormatStatusValue())"
    }

    func statusValue() -> String {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard frameIndex > 0 else { return "0Hz" }
        return audioFormatStatusValue()
    }

    private func configureWriter(_ sampleBuffer: CMSampleBuffer) {
        do {
            let writer = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings(sampleBuffer))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                fail("The audio encoder rejected its input settings")
                return
            }
            writer.add(input)
            self.writer = writer
            self.input = input
        } catch {
            fail("Could not create the audio writer: \(error.localizedDescription)")
        }
    }

    private func writeInfo(_ sampleBuffer: CMSampleBuffer, sessionClock: CMClock?) -> TimeInterval {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sensorTime: CMTime
        if let sessionClock = sessionClock {
            sensorTime = CMSyncConvertTime(presentationTime, from: sessionClock, to: CMClockGetHostTimeClock())
        } else {
            sensorTime = presentationTime
        }
        let sensorSec = CMTimeGetSeconds(sensorTime)
        let utcSec = sensorSec + utcMinusSensorOffsetSec
        let durationSec = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let format = audioFormat(sampleBuffer)
        recordAudioFormat(format)
        writeInfoLine(String(
            format: "%d,%.6f,%.6f,%.6f,%d,%.3f,%d",
            frameIndex,
            sensorSec,
            utcSec,
            durationSec.isFinite ? durationSec : Double.nan,
            sampleCount,
            format.sampleRate,
            format.channels
        ))
        return sensorSec
    }

    private func audioOutputSettings(_ sampleBuffer: CMSampleBuffer) -> [String: Any] {
        let format = audioFormat(sampleBuffer)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
            AVEncoderBitRateKey: format.channels > 1 ? 192_000 : 128_000
        ]
    }

    private func audioFormat(_ sampleBuffer: CMSampleBuffer) -> (sampleRate: Double, channels: Int) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return (sampleRate: 48_000, channels: 1)
        }
        let sampleRate = basicDescription.pointee.mSampleRate > 0 ? basicDescription.pointee.mSampleRate : 48_000
        let channels = max(Int(basicDescription.pointee.mChannelsPerFrame), 1)
        return (sampleRate: sampleRate, channels: channels)
    }

    private func audioFormatStatusValue() -> String {
        guard let sampleRate = latestSampleRate, sampleRate > 0 else { return "0Hz" }
        let sampleRateKHz = sampleRate / 1_000.0
        if abs(sampleRateKHz.rounded() - sampleRateKHz) < 0.05 {
            return String(format: "%.0fkHz", sampleRateKHz)
        }
        return String(format: "%.1fkHz", sampleRateKHz)
    }

    private func writeInfoLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do { try infoHandle?.write(contentsOf: data) }
        catch { fail("Could not write the audio index: \(error.localizedDescription)") }
    }

    private func fail(_ reason: String) {
        guard failureMessage == nil else { return }
        failureMessage = "audio: \(reason)"
        onFailure?(failureMessage!)
    }

    private func recordSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstSensorSec == nil {
            firstSensorSec = sensorSec
        }
        latestSensorSec = sensorSec
    }

    private func recordAudioFormat(_ format: (sampleRate: Double, channels: Int)) {
        statusLock.lock()
        defer { statusLock.unlock() }
        latestSampleRate = format.sampleRate
    }
}

private final class SensorCSVWriter {
    private var handle: FileHandle?

    init(url: URL, header: String) {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        writeLine(header)
    }

    func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        handle?.write(data)
    }

    func close() {
        handle?.synchronizeFile()
        handle?.closeFile()
        handle = nil
    }
}

private final class SensorStreamRecorder {
    struct Options {
        var imuEnabled: Bool
        var deviceMotionEnabled: Bool
        var magnetometerEnabled: Bool
        var barometerEnabled: Bool
    }

    private struct AccelerometerSample {
        let sensorSec: TimeInterval
        let utcSec: TimeInterval
        let x: Double
        let y: Double
        let z: Double
    }

    private static let rawIMUUpdateInterval: TimeInterval = 1.0 / 400.0
    private static let deviceMotionUpdateInterval: TimeInterval = 1.0 / 100.0
    private static let magnetometerUpdateInterval: TimeInterval = 1.0 / 50.0
    private static let standardGravity: Double = 9.80665

    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue
    private let statusLock = NSLock()
    private let utcMinusSensorOffsetSec: TimeInterval
    private var accelerometerWriter: SensorCSVWriter?
    private var gyroscopeWriter: SensorCSVWriter?
    private var imuWriter: SensorCSVWriter?
    private var deviceMotionWriter: SensorCSVWriter?
    private var magnetometerWriter: SensorCSVWriter?
    private var barometerWriter: SensorCSVWriter?
    private var latestAccelerometerSample: AccelerometerSample?
    private var accelerometerCount = 0
    private var gyroscopeCount = 0
    private var imuCount = 0
    private var deviceMotionCount = 0
    private var magnetometerCount = 0
    private var barometerCount = 0
    private var firstAccelerometerSensorSec: TimeInterval?
    private var firstGyroscopeSensorSec: TimeInterval?
    private var firstIMUSensorSec: TimeInterval?
    private var firstDeviceMotionSensorSec: TimeInterval?
    private var firstMagnetometerSensorSec: TimeInterval?
    private var firstBarometerSensorSec: TimeInterval?
    private var latestAccelerometerSensorSec: TimeInterval?
    private var latestGyroscopeSensorSec: TimeInterval?
    private var latestIMUSensorSec: TimeInterval?
    private var latestDeviceMotionSensorSec: TimeInterval?
    private var latestMagnetometerSensorSec: TimeInterval?
    private var latestBarometerSensorSec: TimeInterval?

    init() {
        queue = OperationQueue()
        queue.name = "com.ydsf16.sensorrecorder.sensors"
        queue.maxConcurrentOperationCount = 1
        utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func start(in directory: URL, options: Options) {
        if options.imuEnabled {
            accelerometerWriter = SensorCSVWriter(
                url: directory.appendingPathComponent("accelerometer.csv"),
                header: "sensor_sec,utc_sec,ax_m_s2,ay_m_s2,az_m_s2"
            )
            gyroscopeWriter = SensorCSVWriter(
                url: directory.appendingPathComponent("gyroscope.csv"),
                header: "sensor_sec,utc_sec,gx_rad_s,gy_rad_s,gz_rad_s"
            )
            imuWriter = SensorCSVWriter(
                url: directory.appendingPathComponent("imu.csv"),
                header: "sensor_sec,utc_sec,ax_m_s2,ay_m_s2,az_m_s2,gx_rad_s,gy_rad_s,gz_rad_s,accel_sensor_sec,gyro_sensor_sec"
            )
            startIMUUpdates()
        }

        if options.deviceMotionEnabled {
            deviceMotionWriter = SensorCSVWriter(
                url: directory.appendingPathComponent("device_motion.csv"),
                header: [
                    "sensor_sec",
                    "utc_sec",
                    "qw",
                    "qx",
                    "qy",
                    "qz",
                    "roll",
                    "pitch",
                    "yaw",
                    "gravity_x_m_s2",
                    "gravity_y_m_s2",
                    "gravity_z_m_s2",
                    "user_accel_x_m_s2",
                    "user_accel_y_m_s2",
                    "user_accel_z_m_s2",
                    "rotation_rate_x_rad_s",
                    "rotation_rate_y_rad_s",
                    "rotation_rate_z_rad_s",
                    "magnetic_field_x_uT",
                    "magnetic_field_y_uT",
                    "magnetic_field_z_uT",
                    "magnetic_accuracy",
                    "heading_deg"
                ].joined(separator: ",")
            )
            startDeviceMotionUpdates()
        }

        if options.magnetometerEnabled {
            magnetometerWriter = SensorCSVWriter(
                url: directory.appendingPathComponent("magnetometer.csv"),
                header: "sensor_sec,utc_sec,mx_uT,my_uT,mz_uT"
            )
            startMagnetometerUpdates()
        }

        if options.barometerEnabled {
            barometerWriter = SensorCSVWriter(
                url: directory.appendingPathComponent("barometer.csv"),
                header: "sensor_sec,utc_sec,pressure_kpa,relative_altitude_m"
            )
            startBarometerUpdates()
        }
    }

    func statusText() -> String {
        statusLock.lock()
        defer { statusLock.unlock() }
        var parts = [
            streamStatus(label: "A", count: accelerometerCount, first: firstAccelerometerSensorSec, latest: latestAccelerometerSensorSec),
            streamStatus(label: "G", count: gyroscopeCount, first: firstGyroscopeSensorSec, latest: latestGyroscopeSensorSec),
            streamStatus(label: "IMU", count: imuCount, first: firstIMUSensorSec, latest: latestIMUSensorSec),
            streamStatus(label: "DM", count: deviceMotionCount, first: firstDeviceMotionSensorSec, latest: latestDeviceMotionSensorSec),
            streamStatus(label: "M", count: magnetometerCount, first: firstMagnetometerSensorSec, latest: latestMagnetometerSensorSec),
            streamStatus(label: "B", count: barometerCount, first: firstBarometerSensorSec, latest: latestBarometerSensorSec)
        ]
        parts.removeAll { $0.isEmpty }
        return parts.isEmpty ? "sensors waiting" : parts.joined(separator: " ")
    }

    func statusRows() -> [String: String] {
        statusLock.lock()
        defer { statusLock.unlock() }
        return [
            "accel": streamValue(count: accelerometerCount, first: firstAccelerometerSensorSec, latest: latestAccelerometerSensorSec),
            "gyro": streamValue(count: gyroscopeCount, first: firstGyroscopeSensorSec, latest: latestGyroscopeSensorSec),
            "imu": streamValue(count: imuCount, first: firstIMUSensorSec, latest: latestIMUSensorSec),
            "motion": streamValue(count: deviceMotionCount, first: firstDeviceMotionSensorSec, latest: latestDeviceMotionSensorSec),
            "mag": streamValue(count: magnetometerCount, first: firstMagnetometerSensorSec, latest: latestMagnetometerSensorSec),
            "baro": streamValue(count: barometerCount, first: firstBarometerSensorSec, latest: latestBarometerSensorSec)
        ]
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        queue.addOperation {
            self.accelerometerWriter?.close()
            self.gyroscopeWriter?.close()
            self.imuWriter?.close()
            self.deviceMotionWriter?.close()
            self.magnetometerWriter?.close()
            self.barometerWriter?.close()
            self.accelerometerWriter = nil
            self.gyroscopeWriter = nil
            self.imuWriter = nil
            self.deviceMotionWriter = nil
            self.magnetometerWriter = nil
            self.barometerWriter = nil
            self.latestAccelerometerSample = nil
        }
    }

    private func streamStatus(label: String, count: Int, first: TimeInterval?, latest: TimeInterval?) -> String {
        guard count > 0 else {
            return "\(label) --"
        }
        guard let first = first, let latest = latest, latest > first, count > 1 else {
            return "\(label) \(count)"
        }
        let hz = Double(count - 1) / (latest - first)
        return String(format: "%@ %.0fHz", label, hz)
    }

    private func streamValue(count: Int, first: TimeInterval?, latest: TimeInterval?) -> String {
        guard count > 0 else {
            return "0Hz"
        }
        guard let first = first, let latest = latest, latest > first, count > 1 else {
            return "\(count)"
        }
        let hz = Double(count - 1) / (latest - first)
        return String(format: "%.0fHz", hz)
    }

    private func startIMUUpdates() {
        startAccelerometerUpdates()
        startGyroscopeUpdates()
    }

    private func startAccelerometerUpdates() {
        guard motionManager.isAccelerometerAvailable else {
            accelerometerWriter?.writeLine("# unavailable")
            return
        }
        motionManager.accelerometerUpdateInterval = Self.rawIMUUpdateInterval
        motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    self?.accelerometerWriter?.writeLine("# error,\(error.localizedDescription)")
                }
                return
            }
            let sensorSec = data.timestamp
            let utcSec = sensorSec + self.utcMinusSensorOffsetSec
            let ax = -self.metersPerSecondSquared(fromG: data.acceleration.x)
            let ay = -self.metersPerSecondSquared(fromG: data.acceleration.y)
            let az = -self.metersPerSecondSquared(fromG: data.acceleration.z)
            self.recordAccelerometerSample(sensorSec)
            self.latestAccelerometerSample = AccelerometerSample(
                sensorSec: sensorSec,
                utcSec: utcSec,
                x: ax,
                y: ay,
                z: az
            )
            self.accelerometerWriter?.writeLine(String(
                format: "%.6f,%.6f,%.9f,%.9f,%.9f",
                sensorSec, utcSec, ax, ay, az
            ))
        }
    }

    private func startGyroscopeUpdates() {
        guard motionManager.isGyroAvailable else {
            gyroscopeWriter?.writeLine("# unavailable")
            return
        }
        motionManager.gyroUpdateInterval = Self.rawIMUUpdateInterval
        motionManager.startGyroUpdates(to: queue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    self?.gyroscopeWriter?.writeLine("# error,\(error.localizedDescription)")
                }
                return
            }
            let sensorSec = data.timestamp
            let utcSec = sensorSec + self.utcMinusSensorOffsetSec
            self.recordGyroscopeSample(sensorSec)
            self.gyroscopeWriter?.writeLine(String(
                format: "%.6f,%.6f,%.9f,%.9f,%.9f",
                sensorSec, utcSec, data.rotationRate.x, data.rotationRate.y, data.rotationRate.z
            ))
            guard let accelerometer = self.latestAccelerometerSample else {
                return
            }
            self.recordIMUSample(sensorSec)
            self.imuWriter?.writeLine(String(
                format: "%.6f,%.6f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.6f,%.6f",
                sensorSec,
                utcSec,
                accelerometer.x,
                accelerometer.y,
                accelerometer.z,
                data.rotationRate.x,
                data.rotationRate.y,
                data.rotationRate.z,
                accelerometer.sensorSec,
                sensorSec
            ))
        }
    }

    private func startDeviceMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            deviceMotionWriter?.writeLine("# unavailable")
            return
        }
        motionManager.deviceMotionUpdateInterval = Self.deviceMotionUpdateInterval
        motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    self?.deviceMotionWriter?.writeLine("# error,\(error.localizedDescription)")
                }
                return
            }

            let sensorSec = data.timestamp
            let utcSec = sensorSec + self.utcMinusSensorOffsetSec
            let quaternion = data.attitude.quaternion
            let attitude = data.attitude
            let magneticField = data.magneticField
            let gravityX = self.metersPerSecondSquared(fromG: data.gravity.x)
            let gravityY = self.metersPerSecondSquared(fromG: data.gravity.y)
            let gravityZ = self.metersPerSecondSquared(fromG: data.gravity.z)
            let userAccelX = self.metersPerSecondSquared(fromG: data.userAcceleration.x)
            let userAccelY = self.metersPerSecondSquared(fromG: data.userAcceleration.y)
            let userAccelZ = self.metersPerSecondSquared(fromG: data.userAcceleration.z)
            self.recordDeviceMotionSample(sensorSec)
            self.deviceMotionWriter?.writeLine(String(
                format: "%.6f,%.6f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%d,%.9f",
                sensorSec,
                utcSec,
                quaternion.w,
                quaternion.x,
                quaternion.y,
                quaternion.z,
                attitude.roll,
                attitude.pitch,
                attitude.yaw,
                gravityX,
                gravityY,
                gravityZ,
                userAccelX,
                userAccelY,
                userAccelZ,
                data.rotationRate.x,
                data.rotationRate.y,
                data.rotationRate.z,
                magneticField.field.x,
                magneticField.field.y,
                magneticField.field.z,
                magneticField.accuracy.rawValue,
                data.heading
            ))
        }
    }

    private func metersPerSecondSquared(fromG value: Double) -> Double {
        value * Self.standardGravity
    }

    private func startMagnetometerUpdates() {
        guard motionManager.isMagnetometerAvailable else {
            magnetometerWriter?.writeLine("# unavailable")
            return
        }
        motionManager.magnetometerUpdateInterval = Self.magnetometerUpdateInterval
        motionManager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    self?.magnetometerWriter?.writeLine("# error,\(error.localizedDescription)")
                }
                return
            }
            let sensorSec = data.timestamp
            let utcSec = sensorSec + self.utcMinusSensorOffsetSec
            self.recordMagnetometerSample(sensorSec)
            self.magnetometerWriter?.writeLine(String(
                format: "%.6f,%.6f,%.9f,%.9f,%.9f",
                sensorSec, utcSec, data.magneticField.x, data.magneticField.y, data.magneticField.z
            ))
        }
    }

    private func startBarometerUpdates() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            barometerWriter?.writeLine("# unavailable")
            return
        }
        altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
            guard let self = self, let data = data else {
                if let error = error {
                    self?.barometerWriter?.writeLine("# error,\(error.localizedDescription)")
                }
                return
            }
            let sensorSec = data.timestamp
            let utcSec = sensorSec + self.utcMinusSensorOffsetSec
            self.recordBarometerSample(sensorSec)
            self.barometerWriter?.writeLine(String(
                format: "%.6f,%.6f,%.9f,%.9f",
                sensorSec, utcSec, data.pressure.doubleValue, data.relativeAltitude.doubleValue
            ))
        }
    }

    private func recordAccelerometerSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstAccelerometerSensorSec == nil {
            firstAccelerometerSensorSec = sensorSec
        }
        latestAccelerometerSensorSec = sensorSec
        accelerometerCount += 1
    }

    private func recordGyroscopeSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstGyroscopeSensorSec == nil {
            firstGyroscopeSensorSec = sensorSec
        }
        latestGyroscopeSensorSec = sensorSec
        gyroscopeCount += 1
    }

    private func recordIMUSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstIMUSensorSec == nil {
            firstIMUSensorSec = sensorSec
        }
        latestIMUSensorSec = sensorSec
        imuCount += 1
    }

    private func recordDeviceMotionSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstDeviceMotionSensorSec == nil {
            firstDeviceMotionSensorSec = sensorSec
        }
        latestDeviceMotionSensorSec = sensorSec
        deviceMotionCount += 1
    }

    private func recordMagnetometerSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstMagnetometerSensorSec == nil {
            firstMagnetometerSensorSec = sensorSec
        }
        latestMagnetometerSensorSec = sensorSec
        magnetometerCount += 1
    }

    private func recordBarometerSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstBarometerSensorSec == nil {
            firstBarometerSensorSec = sensorSec
        }
        latestBarometerSensorSec = sensorSec
        barometerCount += 1
    }
}

private final class GeoLocationStreamRecorder {
    private let writer: SensorCSVWriter
    private let utcMinusSensorOffsetSec: TimeInterval
    private var count = 0
    private var firstSensorSec: TimeInterval?
    private var latestSensorSec: TimeInterval?
    private let statusLock = NSLock()

    init(directory: URL) {
        utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        writer = SensorCSVWriter(
            url: directory.appendingPathComponent("geo_location.csv"),
            header: [
                "sensor_sec",
                "utc_sec",
                "latitude",
                "longitude",
                "altitude",
                "horizontal_accuracy_m",
                "vertical_accuracy_m",
                "speed_m_s",
                "speed_accuracy_m_s",
                "course_deg",
                "course_accuracy_deg",
                "valid_position",
                "valid_altitude",
                "valid_speed",
                "valid_course",
                "source_is_simulated",
                "source_is_accessory"
            ].joined(separator: ",")
        )
    }

    func append(_ location: CLLocation) {
        let utcSec = location.timestamp.timeIntervalSince1970
        let sensorSec = utcSec - utcMinusSensorOffsetSec
        let horizontalAccuracy = location.horizontalAccuracy
        let verticalAccuracy = location.verticalAccuracy
        let speed = location.speed
        let course = location.course
        let speedAccuracy = location.speedAccuracy
        let courseAccuracy = location.courseAccuracy
        let validPosition = horizontalAccuracy >= 0
        let validAltitude = verticalAccuracy >= 0
        let validSpeed = speed >= 0
        let validCourse = course >= 0
        let source = location.sourceInformation
        let sourceIsSimulated = source?.isSimulatedBySoftware ?? false
        let sourceIsAccessory = source?.isProducedByAccessory ?? false

        recordSample(sensorSec)
        writer.writeLine(String(
            format: "%.6f,%.6f,%.9f,%.9f,%.9f,%.3f,%.3f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d,%d",
            sensorSec,
            utcSec,
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.altitude,
            horizontalAccuracy,
            verticalAccuracy,
            speed,
            speedAccuracy,
            course,
            courseAccuracy,
            validPosition ? 1 : 0,
            validAltitude ? 1 : 0,
            validSpeed ? 1 : 0,
            validCourse ? 1 : 0,
            sourceIsSimulated ? 1 : 0,
            sourceIsAccessory ? 1 : 0
        ))
    }

    func statusText() -> String {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard count > 0 else { return "L --" }
        guard let first = firstSensorSec, let latest = latestSensorSec, latest > first, count > 1 else {
            return "L \(count)"
        }
        let hz = Double(count - 1) / (latest - first)
        return String(format: "L %.1fHz", hz)
    }

    func statusValue() -> String {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard count > 0 else { return "0Hz" }
        guard let first = firstSensorSec, let latest = latestSensorSec, latest > first, count > 1 else {
            return "\(count)"
        }
        let hz = Double(count - 1) / (latest - first)
        return String(format: "%.1fHz", hz)
    }

    func close() {
        writer.close()
    }

    private func recordSample(_ sensorSec: TimeInterval) {
        statusLock.lock()
        defer { statusLock.unlock() }
        if firstSensorSec == nil {
            firstSensorSec = sensorSec
        }
        latestSensorSec = sensorSec
        count += 1
    }
}

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate, AVCaptureDepthDataOutputDelegate, CLLocationManagerDelegate, ARSessionDelegate {
    private typealias RecordingCamera = PhysicalCamera

    private enum PreviewDebugMode: String {
        case wideOnly = "wide only"
        case ultraWideOnly = "ultrawide only"
        case dual = "dual preview"
    }

    private enum CaptureMode: String, Codable {
        case standard
        case arkit
    }

    private struct CameraCaptureSettings: Codable, Equatable {
        var enabled: Bool
        var resolution: String
        var frameRate: String
        var autoFocus: Bool
        var autoExposure: Bool? = true
        var maxExposureDurationMS: String? = "10"
        var fixedFocusLensPosition: Double?
    }

    private struct CameraCapabilities {
        let hasWide: Bool
        let hasUltraWide: Bool
        let hasFront: Bool
        let hasTelephoto: Bool
        let hasLiDAR: Bool
        let supportsMultiCam: Bool
    }

    private struct RecorderSettings: Codable {
        var settingsVersion: Int
        var captureMode: CaptureMode
        var wide: CameraCaptureSettings
        var ultraWide: CameraCaptureSettings
        var telephoto: CameraCaptureSettings
        var front: CameraCaptureSettings
        var arkitCamera: CameraCaptureSettings
        var imuEnabled: Bool
        var magnetometerEnabled: Bool
        var barometerEnabled: Bool
        var geoLocationEnabled: Bool
        var deviceMotionEnabled: Bool
        var audioEnabled: Bool
        var lidarDepthEnabled: Bool

        private enum CodingKeys: String, CodingKey {
            case settingsVersion
            case captureMode
            case wide
            case ultraWide
            case telephoto
            case front
            case arkitCamera
            case imuEnabled
            case magnetometerEnabled
            case barometerEnabled
            case geoLocationEnabled
            case deviceMotionEnabled
            case audioEnabled
            case lidarDepthEnabled
        }

        init(
            settingsVersion: Int = 1,
            captureMode: CaptureMode = .standard,
            wide: CameraCaptureSettings,
            ultraWide: CameraCaptureSettings,
            telephoto: CameraCaptureSettings,
            front: CameraCaptureSettings,
            arkitCamera: CameraCaptureSettings,
            imuEnabled: Bool,
            magnetometerEnabled: Bool,
            barometerEnabled: Bool,
            geoLocationEnabled: Bool,
            deviceMotionEnabled: Bool,
            audioEnabled: Bool,
            lidarDepthEnabled: Bool
        ) {
            self.settingsVersion = settingsVersion
            self.captureMode = captureMode
            self.wide = wide
            self.ultraWide = ultraWide
            self.telephoto = telephoto
            self.front = front
            self.arkitCamera = arkitCamera
            self.imuEnabled = imuEnabled
            self.magnetometerEnabled = magnetometerEnabled
            self.barometerEnabled = barometerEnabled
            self.geoLocationEnabled = geoLocationEnabled
            self.deviceMotionEnabled = deviceMotionEnabled
            self.audioEnabled = audioEnabled
            self.lidarDepthEnabled = lidarDepthEnabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self.defaults
            settingsVersion = try container.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 0
            captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? defaults.captureMode
            wide = try container.decodeIfPresent(CameraCaptureSettings.self, forKey: .wide) ?? defaults.wide
            ultraWide = try container.decodeIfPresent(CameraCaptureSettings.self, forKey: .ultraWide) ?? defaults.ultraWide
            telephoto = try container.decodeIfPresent(CameraCaptureSettings.self, forKey: .telephoto) ?? defaults.telephoto
            front = try container.decodeIfPresent(CameraCaptureSettings.self, forKey: .front) ?? defaults.front
            arkitCamera = try container.decodeIfPresent(CameraCaptureSettings.self, forKey: .arkitCamera) ?? defaults.arkitCamera
            imuEnabled = try container.decodeIfPresent(Bool.self, forKey: .imuEnabled) ?? defaults.imuEnabled
            magnetometerEnabled = try container.decodeIfPresent(Bool.self, forKey: .magnetometerEnabled) ?? defaults.magnetometerEnabled
            barometerEnabled = try container.decodeIfPresent(Bool.self, forKey: .barometerEnabled) ?? defaults.barometerEnabled
            geoLocationEnabled = try container.decodeIfPresent(Bool.self, forKey: .geoLocationEnabled) ?? defaults.geoLocationEnabled
            deviceMotionEnabled = try container.decodeIfPresent(Bool.self, forKey: .deviceMotionEnabled) ?? defaults.deviceMotionEnabled
            audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? defaults.audioEnabled
            lidarDepthEnabled = try container.decodeIfPresent(Bool.self, forKey: .lidarDepthEnabled) ?? defaults.lidarDepthEnabled
        }

        static let defaults = RecorderSettings(
            captureMode: .standard,
            wide: CameraCaptureSettings(
                enabled: true,
                resolution: "1920x1440",
                frameRate: "30",
                autoFocus: false,
                autoExposure: true,
                maxExposureDurationMS: "10",
                fixedFocusLensPosition: 0.6
            ),
            ultraWide: CameraCaptureSettings(
                enabled: true,
                resolution: "1920x1440",
                frameRate: "30",
                autoFocus: false,
                autoExposure: true,
                maxExposureDurationMS: "10",
                fixedFocusLensPosition: 0.8
            ),
            telephoto: CameraCaptureSettings(
                enabled: false,
                resolution: "1920x1440",
                frameRate: "30",
                autoFocus: false,
                autoExposure: true,
                maxExposureDurationMS: "10",
                fixedFocusLensPosition: 0.6
            ),
            front: CameraCaptureSettings(
                enabled: false,
                resolution: "1920x1440",
                frameRate: "30",
                autoFocus: true,
                autoExposure: true,
                maxExposureDurationMS: "10",
                fixedFocusLensPosition: 0.6
            ),
            arkitCamera: CameraCaptureSettings(
                enabled: true,
                resolution: "1920x1440",
                frameRate: "30",
                autoFocus: false,
                autoExposure: true,
                maxExposureDurationMS: "5",
                fixedFocusLensPosition: 0.6
            ),
            imuEnabled: true,
            magnetometerEnabled: true,
            barometerEnabled: true,
            geoLocationEnabled: true,
            deviceMotionEnabled: true,
            audioEnabled: true,
            lidarDepthEnabled: true
        )

        private static let storageKey = "sensor_recorder.settings.v1"
        private static let configFileName = "sensor_recorder_settings.json"

        static func load() -> RecorderSettings {
            if let data = try? Data(contentsOf: configFileURL),
               let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data) {
                return migratedSettingsIfNeeded(settings)
            }
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data) else {
                return defaults
            }
            return migratedSettingsIfNeeded(settings)
        }

        private static func migratedSettingsIfNeeded(_ loadedSettings: RecorderSettings) -> RecorderSettings {
            guard loadedSettings.settingsVersion < defaults.settingsVersion else {
                return loadedSettings
            }

            var migrated = loadedSettings
            migrated.arkitCamera.autoFocus = defaults.arkitCamera.autoFocus
            migrated.arkitCamera.maxExposureDurationMS = defaults.arkitCamera.maxExposureDurationMS
            migrated.settingsVersion = defaults.settingsVersion
            migrated.save()
            return migrated
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let prettyData = try? encoder.encode(self) {
                try? prettyData.write(to: Self.configFileURL, options: .atomic)
            }
        }

        private static var configFileURL: URL {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SensorRecorder", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
                .appendingPathComponent(configFileName)
        }
    }

    private enum CapturePermission {
        case camera
        case microphone
        case location
        case motion

        var statusText: String {
            switch self {
            case .camera: return "Camera permission"
            case .microphone: return "Microphone permission"
            case .location: return "Location permission"
            case .motion: return "Motion permission"
            }
        }

        var alertTitle: String {
            switch self {
            case .camera: return "Camera Access Needed"
            case .microphone: return "Microphone Access Needed"
            case .location: return "Location Access Needed"
            case .motion: return "Motion Access Needed"
            }
        }

        var deniedMessage: String {
            switch self {
            case .camera:
                return "Camera permission was denied. Please enable Camera in Settings to show preview and record video."
            case .microphone:
                return "Microphone permission was denied. Please enable Microphone in Settings or turn Audio off in Sensor Recorder settings."
            case .location:
                return "Location permission was denied. Please enable Location in Settings or turn GeoLoc off in Sensor Recorder settings."
            case .motion:
                return "Motion & Fitness permission was denied. Please enable Motion & Fitness in Settings or turn IMU/Mag/Baro/Motion off in Sensor Recorder settings."
            }
        }
    }

    // cellphone screen UI outlet objects
    @IBOutlet weak var startStopButton: UIButton!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var trackingStatusLabel: UILabel!
    @IBOutlet weak var mappingStatusLabel: UILabel!
    @IBOutlet weak var frameCounterLabel: UILabel!
    @IBOutlet weak var fileSizeLabel: UILabel!
    @IBOutlet weak var fpsLabel: UILabel!
    @IBOutlet weak var fpsStepper: UIStepper!
    @IBOutlet weak var timeWriteLabel: UILabel!

    @IBOutlet var sceneView: UIView!

    private var legacyControlPanel: UIView?
    private var settingsOverlayView: UIView?
    private var settingsController: PortraitSettingsViewController?
    private weak var settingsSaveButton: UIButton?
    private weak var settingsValidationLabel: UILabel?
    private weak var settingsPurchaseStatusLabel: UILabel?
    private weak var settingsRetryButton: UIButton?
    private var recorderSettings = RecorderSettings.load()
    private var settingsMenuButtons: [String: UIButton] = [:]
    private var settingsSwitches: [String: UISwitch] = [:]
    private var settingsSliders: [String: UISlider] = [:]
    private var settingsSliderValueLabels: [String: UILabel] = [:]
    private var cameraSettingsGroups: [String: UIView] = [:]
    private var settingsCameraContainer: UIStackView?
    private weak var settingsRailButton: UIButton?
    private weak var filesRailButton: UIButton?
    private var cameraStatusRows: [String: UILabel] = [:]
    private var sensorStatusRows: [String: UILabel] = [:]
    private var captureStatusRows: [String: UILabel] = [:]
    private var cameraStatusBadges: [String: UIView] = [:]
    private var captureStatusBadges: [String: UIView] = [:]
    private var modeBadge: UIView?
    private var modeBadgeLabel: UILabel?
    private var arkitTrackingState: ARCamera.TrackingState = .notAvailable
    private var freeCountdownLabel: UILabel?
    private var rightControlRail: UIView?
    private var sensorMonitorBar: UIView?
    private var hudContentRect: CGRect = .zero
    private let overlayFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private let overlayValueFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    private lazy var session: AVCaptureSession = makeCaptureSession(for: recorderSettings)
    private var multiCameraGraph: MultiCameraCaptureGraph?
    private var validatedMultiCameraFormats: [String: [String: AVCaptureDevice.Format]] = [:]
    private var standardSynchronizer: AVCaptureDataOutputSynchronizer?
    private var configuredCameraFormats: [String: AVCaptureDevice.Format] = [:]
    private var synchronizationWriter: SensorCSVWriter?
    private var synchronizationGroup: Int64 = 0
    private var synchronizationDroppedGroups = 0
    private var synchronizationMaxSkew = 0.0
    private var initialRecordingSamples: [RecordingCamera: CMSampleBuffer] = [:]
    private var timestampAlignmentSummary: TimestampAlignment.Summary?
    private var synchronizationOrigin: CMTime?
    private var synchronizationOriginSensorSec: TimeInterval?
    private var recordingBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var deferredRecordingError: String?
    private var previewSampleSizes: [RecordingCamera: String] = [:]

    private var captureCadence: [RecordingCamera: (first: Double, latest: Double, count: Int, published: Double)] = [:]
    private var measuredCameraFPS: [RecordingCamera: Double] = [:] // main thread UI snapshot
    private var measuredCameraSizes: [RecordingCamera: String] = [:]
    private var captureRecordingActive = false // sessionQueue owns capture admission.
    private var recordingAdmissionSensorSec: TimeInterval?
    private var recordingFailure: String?

    private var singlePreviewSession: AVCaptureSession?
    private var singlePreviewLayer: AVCaptureVideoPreviewLayer?
    private var singlePreviewView: CameraPreviewView?
    private var wideCameraPreviewView: CameraPreviewView?
    private var ultraWideCameraPreviewView: CameraPreviewView?
    private var telephotoCameraPreviewView: CameraPreviewView?
    private var frontCameraPreviewView: CameraPreviewView?
    private var depthPreviewView: UIImageView?
    private var singleVideoOutput: AVCaptureVideoDataOutput?
    private var singleFrameCount = 0
    private var diagnosticLayer: CALayer?
    private let sessionQueue = DispatchQueue(label: "com.ydsf16.sensorrecorder.capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let arkitFrameQueue = DispatchQueue(label: "com.ydsf16.sensorrecorder.arkit.frames", qos: .userInitiated)
    private let arkitDepthQueue = DispatchQueue(label: "com.ydsf16.sensorrecorder.arkit.depth", qos: .utility)
    private let arkitDepthBackpressure = DispatchSemaphore(value: 2)

    private var wideVideoPort: AVCaptureInput.Port?
    private var ultraWideVideoPort: AVCaptureInput.Port?
    private var telephotoVideoPort: AVCaptureInput.Port?
    private var frontVideoPort: AVCaptureInput.Port?
    private var lidarDepthPort: AVCaptureInput.Port?
    private var wideDevice: AVCaptureDevice?
    private var ultraWideDevice: AVCaptureDevice?
    private var telephotoDevice: AVCaptureDevice?
    private var frontDevice: AVCaptureDevice?
    private var lidarDevice: AVCaptureDevice?
    private var widePreviewOutput: AVCaptureVideoDataOutput?
    private var ultraWidePreviewOutput: AVCaptureVideoDataOutput?
    private var telephotoPreviewOutput: AVCaptureVideoDataOutput?
    private var frontPreviewOutput: AVCaptureVideoDataOutput?
    private var lidarDepthOutput: AVCaptureDepthDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var wideRecorder: CameraStreamRecorder?
    private var ultraWideRecorder: CameraStreamRecorder?
    private var telephotoRecorder: CameraStreamRecorder?
    private var frontRecorder: CameraStreamRecorder?
    private var lidarDepthRecorder: LiDARDepthStreamRecorder?
    private var audioRecorder: AudioStreamRecorder?
    private var sensorRecorder: SensorStreamRecorder?
    private var arSession: ARSession?
    private var arkitRecorder: ARKitFrameRecorder?
    private var arkitDisplayLayer: AVSampleBufferDisplayLayer?
    private var arkitFrameCount = 0
    private var arkitPreviewEnqueuePending = false
    private var arkitLastRecordSlot: Int64?
    private var arkitConfiguration: ARWorldTrackingConfiguration?
    private var arkitCaptureDevice: AVCaptureDevice?
    private var arkitDeviceConfigured = false
    private var arkitAudioSession: AVCaptureSession?
    private let locationManager = CLLocationManager()
    private var locationRecorder: GeoLocationStreamRecorder?
    private var wideDisplayLayer: AVSampleBufferDisplayLayer?
    private var ultraWideDisplayLayer: AVSampleBufferDisplayLayer?
    private var telephotoDisplayLayer: AVSampleBufferDisplayLayer?
    private var frontDisplayLayer: AVSampleBufferDisplayLayer?
    private var widePreviewEnqueuePending = false
    private var ultraWidePreviewEnqueuePending = false
    private var telephotoPreviewEnqueuePending = false
    private var frontPreviewEnqueuePending = false
    private var wideFrameCount = 0
    private var ultraWideFrameCount = 0
    private var telephotoFrameCount = 0
    private var frontFrameCount = 0
    private var lidarDepthFrameCount = 0
    private var firstDepthSensorSec: TimeInterval?
    private var latestDepthSensorSec: TimeInterval?
    private var widePreviewLayer: AVCaptureVideoPreviewLayer?
    private var ultraWidePreviewLayer: AVCaptureVideoPreviewLayer?
    private var telephotoPreviewLayer: AVCaptureVideoPreviewLayer?
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    private var depthPreviewImage: UIImage?

    private var isConfigured = false
    private var previewConfigurationFailure: String?
    private var pendingPreviewCompletion: ((String?) -> Void)?
    private var settingsCapabilityGeneration = UUID()
    private var settingsMenuHasCandidates: [String: Bool] = [:]
    private var isRecording = false
    // Main-thread UI state: keep configuration frozen until preparation or
    // every writer's finalization has finished, not merely until Stop is tapped.
    private enum RecordingTransition { case none, preparing, finishing }
    private var recordingTransition = RecordingTransition.none {
        didSet {
            if isViewLoaded { updateAuxiliaryRailButtons(isRecording: isRecording) }
        }
    }
    private var recordingGridOriginSec: TimeInterval?
    private var pendingLocationPermissionCompletion: ((Bool) -> Void)?
    private let defaultCameraAutoExposureMaxDurationMS = "10"
    private let defaultWideFixedFocusLensPosition = 0.6
    private let defaultUltraWideFixedFocusLensPosition = 0.8
    private let defaultTelephotoFixedFocusLensPosition = 0.6
    private let defaultFrontFixedFocusLensPosition = 0.6
    private let defaultARKitFixedFocusLensPosition = 0.6
    private let depthEnabledCameraFrameRateLimit = 10.0
    private let freeRecordingLimitSeconds: TimeInterval = 120
    private let freeCountdownVisibleThresholdSeconds: TimeInterval = 20
    private let embedAudioInCameraMP4 = false
    private let previewOnlyMode = false
    private let previewDebugMode: PreviewDebugMode = .dual
    private var observesSessionRuntimeErrors = false
    private var freeRecordingLimitStopRequested = false
    private var outDirURL: URL!
    private var diskCapacity: String = "?"
    private var startTime: Date!
    private var recordingTimer: Timer?
    private var recBlinkTimer: Timer?
    private var recBlinkVisible = true

    private var hasEnabledCamera: Bool {
        enabledCameraCount(in: recorderSettings) > 0
    }

    private var isARKitMode: Bool {
        recorderSettings.captureMode == .arkit && ARWorldTrackingConfiguration.isSupported
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscapeRight
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override var shouldAutorotate: Bool {
        false
    }

    private var needsRunningCaptureSession: Bool {
        if isARKitMode { return false }
        return hasEnabledCamera || recorderSettings.lidarDepthEnabled || recorderSettings.audioEnabled
    }

    private func makeCaptureSession(for settings: RecorderSettings) -> AVCaptureSession {
        if (enabledCameraCount(in: settings) > 1 || settings.lidarDepthEnabled) && AVCaptureMultiCamSession.isMultiCamSupported {
            return AVCaptureMultiCamSession()
        }
        return AVCaptureSession()
    }

    private func enabledCameraCount(in settings: RecorderSettings) -> Int {
        [settings.wide.enabled, settings.ultraWide.enabled, settings.telephoto.enabled, settings.front.enabled].filter { $0 }.count
    }

    private enum CameraKey: String {
        case wide
        case ultra
        case telephoto
        case front
    }

    private let cameraPreferenceOrder: [CameraKey] = [.wide, .ultra, .telephoto, .front]
    // Legacy ARKit preference migration only. Standard camera sets are SDK-derived.
    private let legacyARKitPreferenceCameraLimit = 3

    private func cameraCapabilities() -> CameraCapabilities {
        CameraCapabilities(
            hasWide: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil,
            hasUltraWide: AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil,
            hasFront: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil,
            hasTelephoto: AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil,
            hasLiDAR: AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil,
            supportsMultiCam: AVCaptureMultiCamSession.isMultiCamSupported
        )
    }

    private func sanitizeRecorderSettingsForCurrentDevice() {
        let capabilities = cameraCapabilities()
        var updated = recorderSettings
        updated.wide = sanitizedCameraCaptureSettings(
            updated.wide,
            defaultLensPosition: defaultWideFixedFocusLensPosition
        )
        updated.ultraWide = sanitizedCameraCaptureSettings(
            updated.ultraWide,
            defaultLensPosition: defaultUltraWideFixedFocusLensPosition
        )
        updated.telephoto = sanitizedCameraCaptureSettings(
            updated.telephoto,
            defaultLensPosition: defaultTelephotoFixedFocusLensPosition
        )
        updated.front = sanitizedCameraCaptureSettings(
            updated.front,
            defaultLensPosition: defaultFrontFixedFocusLensPosition
        )
        updated.arkitCamera = sanitizedCameraCaptureSettings(
            updated.arkitCamera,
            defaultLensPosition: defaultARKitFixedFocusLensPosition
        )

        // Standard settings are a requested configuration. An unavailable camera
        // or combination must be reported, including after relaunch, rather than
        // silently rewriting the saved request.
        if updated.captureMode == .standard {
            recorderSettings = updated
            return
        }

        if updated.captureMode == .arkit && !ARWorldTrackingConfiguration.isSupported {
            updated.captureMode = .standard
        }

        if updated.wide.enabled && !capabilities.hasWide {
            updated.wide.enabled = false
        }
        if updated.ultraWide.enabled && !capabilities.hasUltraWide {
            updated.ultraWide.enabled = false
        }
        if updated.telephoto.enabled && !capabilities.hasTelephoto {
            updated.telephoto.enabled = false
        }
        if updated.front.enabled && !capabilities.hasFront {
            updated.front.enabled = false
        }
        if updated.lidarDepthEnabled && !capabilities.hasLiDAR {
            updated.lidarDepthEnabled = false
        }

        if enabledCameraCount(in: updated) > 1 && !capabilities.supportsMultiCam {
            updated.telephoto.enabled = false
            updated.front.enabled = false
            updated.ultraWide.enabled = false
        }

        enforceMaxConcurrentCameras(settings: &updated)
        while enabledCameraCount(in: updated) > 1 && !isCameraSetSupportedByMultiCam(settings: updated) {
            guard disableLowestPriorityCamera(in: &updated) != nil else { break }
        }

        if enabledCameraCount(in: updated) == 0 && capabilities.hasWide {
            updated.wide.enabled = true
        }

        if updated.captureMode != recorderSettings.captureMode ||
            updated.wide != recorderSettings.wide ||
            updated.ultraWide != recorderSettings.ultraWide ||
            updated.telephoto != recorderSettings.telephoto ||
            updated.front != recorderSettings.front ||
            updated.arkitCamera != recorderSettings.arkitCamera ||
            updated.lidarDepthEnabled != recorderSettings.lidarDepthEnabled {
            recorderSettings = updated
            recorderSettings.save()
        }
    }

    private func enforceMaxConcurrentCameras(settings: inout RecorderSettings) {
        while enabledCameraCount(in: settings) > legacyARKitPreferenceCameraLimit {
            guard disableLowestPriorityCamera(in: &settings) != nil else { break }
        }
    }

    @discardableResult
    private func disableLowestPriorityCamera(in settings: inout RecorderSettings) -> CameraKey? {
        for key in cameraPreferenceOrder.reversed() where isCameraEnabled(key, in: settings) {
            setCameraEnabled(key, enabled: false, in: &settings)
            return key
        }
        return nil
    }

    private func isCameraEnabled(_ key: CameraKey, in settings: RecorderSettings) -> Bool {
        switch key {
        case .wide:
            return settings.wide.enabled
        case .ultra:
            return settings.ultraWide.enabled
        case .telephoto:
            return settings.telephoto.enabled
        case .front:
            return settings.front.enabled
        }
    }

    private func setCameraEnabled(_ key: CameraKey, enabled: Bool, in settings: inout RecorderSettings) {
        switch key {
        case .wide:
            settings.wide.enabled = enabled
        case .ultra:
            settings.ultraWide.enabled = enabled
        case .telephoto:
            settings.telephoto.enabled = enabled
        case .front:
            settings.front.enabled = enabled
        }
    }

    private func isCameraSetSupportedByMultiCam(settings: RecorderSettings) -> Bool {
        if settings.captureMode == .standard && enabledCameraCount(in: settings) > 1 {
            return !settings.lidarDepthEnabled && MultiCameraCaptureGraph.inputGroups(for: enabledPhysicalCameras(settings)) != nil
        }
        let wantedDevices = activeCameraDevices(for: settings)
        guard wantedDevices.count > 1 else { return true }
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return false }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInLiDARDepthCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.supportedMultiCamDeviceSets.contains { supportedSet in
            wantedDevices.allSatisfy { device in supportedSet.contains(device) }
        }
    }

    private func activeCameraDevices(for settings: RecorderSettings) -> [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        if settings.ultraWide.enabled,
           let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            devices.append(device)
        }
        if settings.wide.enabled,
           let device = AVCaptureDevice.default(
            settings.lidarDepthEnabled ? .builtInLiDARDepthCamera : .builtInWideAngleCamera,
            for: .video,
            position: .back
           ) {
            devices.append(device)
        }
        if settings.telephoto.enabled,
           let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            devices.append(device)
        }
        if settings.front.enabled,
           let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            devices.append(device)
        }
        if settings.lidarDepthEnabled && !settings.wide.enabled,
           let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
            devices.append(device)
        }
        return devices
    }

    private func sanitizedCameraCaptureSettings(
        _ settings: CameraCaptureSettings,
        defaultLensPosition: Double
    ) -> CameraCaptureSettings {
        var sanitized = settings
        sanitized.autoExposure = isAutoExposureEnabled(for: sanitized)
        if sanitized.maxExposureDurationMS == nil ||
            !["1", "5", "10", "20", "30"].contains(maxExposureDurationLabel(for: sanitized)) {
            sanitized.maxExposureDurationMS = defaultCameraAutoExposureMaxDurationMS
        }
        sanitized.fixedFocusLensPosition = clampedLensPosition(
            sanitized.fixedFocusLensPosition,
            fallback: defaultLensPosition
        )
        return sanitized
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        PurchaseManager.shared.start()
        recorderSettings = RecorderSettings.load()
        sanitizeRecorderSettingsForCurrentDevice()
        view.backgroundColor = .black
        updateDiskCapacity()
        installLandscapeOverlay()
        initializeUI()
        startStopButton.isEnabled = false
        sceneView.backgroundColor = .black
        sceneView.layer.borderWidth = 0
        configureLocationManager()
        NotificationCenter.default.addObserver(self, selector: #selector(recordingAppDidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordingAppDidBecomeActive), name: UIScene.didActivateNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        PurchaseManager.shared.stop()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--validate-capture-matrix") {
            beginCaptureMatrixValidation()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--inspect-hardware") {
            inspectHardwareForTesting()
            return
        }
#endif
        if isConfigured && !isRecording && needsRunningCaptureSession {
            sessionQueue.async { self.session.startRunning() }
        }
        preparePreviewSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPreviewLayers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        singlePreviewSession?.stopRunning()
        if !isRecording && isConfigured {
            sessionQueue.async {
                self.session.stopRunning()
            }
        }
    }

#if DEBUG
    // Integration instrumentation only: uses the production planner, preview,
    // recorder and entitlement timer. It never saves test settings to disk.
    private var matrixStatus: UILabel?
    private var matrixProfiles: [RecorderSettings] = []
    private var matrixResults: [[String: Any]] = []
    private var matrixIndex = 0
    private var matrixEnd = 0
    private var matrixOriginalSettings: RecorderSettings?
    private var matrixRunID = UUID().uuidString

    private func beginCaptureMatrixValidation() {
        guard matrixStatus == nil else { return }
        matrixOriginalSettings = recorderSettings
        let label = UILabel(frame: CGRect(x: 20, y: 60, width: 760, height: 60))
        label.accessibilityIdentifier = "validation.status"
        label.accessibilityValue = "planning"
        label.text = "Planning real-device capture traversal…"
        label.textColor = .white
        label.backgroundColor = .black
        view.addSubview(label)
        matrixStatus = label
        var base = recorderSettings
        base.captureMode = .standard
        base.lidarDepthEnabled = false
        base.audioEnabled = false
        base.imuEnabled = true
        base.deviceMotionEnabled = true
        base.geoLocationEnabled = false
        base.magnetometerEnabled = false
        base.barometerEnabled = false
        for key in ["wide", "ultra", "telephoto", "front"] {
            switch key {
            case "wide": base.wide.autoExposure = true; base.wide.maxExposureDurationMS = "10"; base.wide.autoFocus = true
            case "ultra": base.ultraWide.autoExposure = true; base.ultraWide.maxExposureDurationMS = "10"; base.ultraWide.autoFocus = true
            case "telephoto": base.telephoto.autoExposure = true; base.telephoto.maxExposureDurationMS = "10"; base.telephoto.autoFocus = true
            default: base.front.autoExposure = true; base.front.maxExposureDurationMS = "10"; base.front.autoFocus = true
            }
        }
        ensurePermissions(requiredPermissions(for: base)) { granted in
            guard granted else { label.accessibilityValue = "failed"; return }
            self.sessionQueue.async {
                let profiles: [RecorderSettings] = self.withRestoredCaptureDevices {
                    var profiles: [RecorderSettings] = []
                    for (_, candidate) in self.combinationCandidates(base) {
                        for resolution in self.commonResolutionChoices(candidate).reversed() {
                            let sized = self.replacingCaptureValue(candidate, key: "shared.resolution", value: resolution)
                            for rate in self.commonRateChoices(sized) {
                                let profile = self.replacingCaptureValue(sized, key: "shared.frameRate", value: rate)
                                if self.jointConfigurationFits(profile) { profiles.append(profile) }
                            }
                        }
                    }
                    return profiles
                }
                DispatchQueue.main.async {
                    let args = ProcessInfo.processInfo.arguments
                    self.matrixProfiles = args.contains("--matrix-hardware-only")
                        ? profiles.filter { self.enabledCameraCount(in: $0) > 1 && !$0.front.enabled }
                        : args.contains("--matrix-multicamera-only") ? profiles.filter { self.enabledCameraCount(in: $0) > 1 } : profiles
                    let profileCount = self.matrixProfiles.count
                    func argument(_ flag: String, fallback: Int) -> Int {
                        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return fallback }
                        return Int(args[index + 1]) ?? fallback
                    }
                    self.matrixIndex = max(0, min(profileCount, argument("--matrix-offset", fallback: 0)))
                    self.matrixEnd = min(profileCount, self.matrixIndex + max(0, argument("--matrix-count", fallback: profileCount)))
                    do {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(profiles).write(to: self.getRecDir().appendingPathComponent("capture-validation-profiles.json"), options: .atomic)
                        self.runNextMatrixProfile()
                    } catch { label.text = error.localizedDescription; label.accessibilityValue = "failed" }
                }
            }
        }
    }

    private func runNextMatrixProfile() {
        if matrixIndex >= matrixEnd {
            UIApplication.shared.isIdleTimerDisabled = false
            if let original = matrixOriginalSettings { recorderSettings = original }
            matrixStatus?.text = "Traversal finished: \(matrixResults.count) recordings"
            matrixStatus?.accessibilityValue = "done"
            sessionQueue.async { self.session.stopRunning() }
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            matrixStatus?.text = "Cooling before profile \(matrixIndex)…"
            sessionQueue.async { self.session.stopRunning() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.runNextMatrixProfile() }
            return
        }
        let settings = matrixProfiles[matrixIndex]
        let reference = [(settings.wide), settings.ultraWide, settings.telephoto, settings.front].first { $0.enabled }!
        matrixStatus?.text = "\(matrixIndex + 1)/\(matrixProfiles.count) \(combinationTitle(settings)) \(reference.resolution) @\(reference.frameRate)"
        matrixStatus?.accessibilityValue = "running:\(matrixIndex)"
        recorderSettings = settings
        resetPreviewSessionForSettingsChange { issue in
            if let issue { self.finishMatrixProfile(error: issue, directory: nil); return }
            // Allow native AE/AF to settle before recording; do not synthesize samples.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                self.startRecording()
                self.waitForMatrixRecording(deadline: Date().addingTimeInterval(20), rate: Double(reference.frameRate) ?? 30)
            }
        }
    }

    private func waitForMatrixRecording(deadline: Date, rate: Double) {
        if isRecording {
            let directory = outDirURL?.lastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + max(3, 8 / rate)) {
                if self.isRecording { self.stopRecording() }
                self.waitForMatrixFinish(deadline: Date().addingTimeInterval(30), directory: directory)
            }
        } else if Date() < deadline && presentedViewController == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForMatrixRecording(deadline: deadline, rate: rate) }
        } else {
            let alert = presentedViewController as? UIAlertController
            finishMatrixProfile(error: recordingFailure ?? alert?.message ?? "Recording did not start", directory: outDirURL?.lastPathComponent)
        }
    }

    private func waitForMatrixFinish(deadline: Date, directory: String?) {
        if startStopButton.accessibilityValue == "idle" && startStopButton.isEnabled {
            finishMatrixProfile(error: recordingFailure, directory: directory)
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForMatrixFinish(deadline: deadline, directory: directory) }
        } else {
            matrixStatus?.text = "Writer finalization timed out; traversal stopped"
            matrixStatus?.accessibilityValue = "failed"
        }
    }

    private func finishMatrixProfile(error: String?, directory: String?) {
        let profile = matrixProfiles[matrixIndex]
        var result: [String: Any] = ["index": matrixIndex, "combination": combinationTitle(profile),
                                   "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                                   "profile": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))) ?? [:]]
        result["directory"] = directory ?? NSNull()
        result["error"] = error ?? NSNull()
        matrixResults.append(result)
        do {
            let data = try JSONSerialization.data(withJSONObject: ["run_id": matrixRunID, "total_profiles": matrixProfiles.count,
                                                                 "results": matrixResults], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: getRecDir().appendingPathComponent("capture-validation-\(matrixRunID).json"), options: .atomic)
        } catch {
            matrixStatus?.text = error.localizedDescription; matrixStatus?.accessibilityValue = "failed"; return
        }
        if let alert = presentedViewController as? UIAlertController { alert.dismiss(animated: false) }
        matrixIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runNextMatrixProfile() }
    }

    private func inspectHardwareForTesting() {
        let status = UILabel()
        status.accessibilityIdentifier = "validation.status"
        status.accessibilityValue = "running"
        status.text = "Inspecting camera hardware…"
        status.textColor = .white
        status.backgroundColor = .black
        status.frame = CGRect(x: 20, y: 60, width: 600, height: 50)
        view.addSubview(status)
        requestCameraAccess { granted in
            guard granted else { status.accessibilityValue = "permission_denied"; return }
            self.sessionQueue.async {
                let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera]
                let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
                let devices = discovery.devices
                let entries: [[String: Any]] = devices.map { device in
                    var entry: [String: Any] = ["id": device.uniqueID, "type": device.deviceType.rawValue,
                        "virtual": device.isVirtualDevice, "position": device.position.rawValue,
                        "constituents": device.constituentDevices.map { $0.deviceType.rawValue },
                        "custom_focus": device.isLockingFocusWithCustomLensPositionSupported,
                        "autofocus": device.isFocusModeSupported(.continuousAutoFocus),
                        "formats": device.formats.map { format -> [String: Any] in
                            ["resolution": self.formatResolution(format), "multicam": format.isMultiCamSupported,
                             "binned": format.isVideoBinned,
                             "rates": format.videoSupportedFrameRateRanges.map { [$0.minFrameRate, $0.maxFrameRate] }]
                        }]
                    if device.isVirtualDevice {
                        do {
                            let graph = AVCaptureMultiCamSession()
                            let input = try AVCaptureDeviceInput(device: device)
                            graph.beginConfiguration()
                            let added = graph.canAddInput(input)
                            if added { graph.addInputWithNoConnections(input) }
                            entry["input_added"] = added
                            entry["constituent_ports"] = device.constituentDevices.map { child -> [String: Any] in
                                let ports = input.ports(for: .video, sourceDeviceType: child.deviceType, sourceDevicePosition: child.position)
                                return ["type": child.deviceType.rawValue, "ports": ports.count,
                                        "resolutions": ports.compactMap { port -> String? in
                                            guard let desc = port.formatDescription else { return nil }
                                            let size = CMVideoFormatDescriptionGetDimensions(desc)
                                            return "\(size.width)x\(size.height)"
                                        }]
                            }
                            if added { graph.removeInput(input) }
                            graph.commitConfiguration()
                        } catch { entry["input_error"] = error.localizedDescription }
                    }
                    return entry
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: self.getRecDir().appendingPathComponent("hardware-capabilities.json"), options: .atomic)
                    let simultaneousSets = discovery.supportedMultiCamDeviceSets.map { set in
                        set.map { device in ["id": device.uniqueID, "type": device.deviceType.rawValue,
                                             "position": device.position.rawValue] as [String: Any] }
                    }
                    let combinations = try JSONSerialization.data(withJSONObject: simultaneousSets, options: [.prettyPrinted, .sortedKeys])
                    try combinations.write(to: self.getRecDir().appendingPathComponent("hardware-combinations.json"), options: .atomic)
                    DispatchQueue.main.async { status.text = "Hardware inspection complete"; status.accessibilityValue = "done" }
                } catch {
                    DispatchQueue.main.async { status.text = error.localizedDescription; status.accessibilityValue = "failed" }
                }
            }
        }
    }
#endif

    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        ensurePermission(.camera, completion: completion)
    }

    private func requestAudioAccess(_ completion: @escaping (Bool) -> Void) {
        ensurePermission(.microphone, completion: completion)
    }

    private func requiredPermissions(for settings: RecorderSettings) -> [CapturePermission] {
        var permissions: [CapturePermission] = []
        if enabledCameraCount(in: settings) > 0 || settings.lidarDepthEnabled {
            permissions.append(.camera)
        }
        if settings.audioEnabled {
            permissions.append(.microphone)
        }
        if settings.geoLocationEnabled {
            permissions.append(.location)
        }
        if settings.imuEnabled || settings.magnetometerEnabled || settings.barometerEnabled || settings.deviceMotionEnabled {
            permissions.append(.motion)
        }
        return permissions
    }

    private func ensurePermissions(_ permissions: [CapturePermission], completion: @escaping (Bool) -> Void) {
        var remaining = permissions
        guard !remaining.isEmpty else {
            completion(true)
            return
        }

        let permission = remaining.removeFirst()
        ensurePermission(permission) { granted in
            guard granted else {
                completion(false)
                return
            }
            self.ensurePermissions(remaining, completion: completion)
        }
    }

    private func ensurePermission(_ permission: CapturePermission, completion: @escaping (Bool) -> Void) {
        setStatus(permission.statusText)
        switch permission {
        case .camera:
            ensureAVPermission(.video, permission: permission, completion: completion)
        case .microphone:
            ensureAVPermission(.audio, permission: permission, completion: completion)
        case .location:
            ensureLocationPermission(completion)
        case .motion:
            ensureMotionPermission(completion)
        }
    }

    private func ensureAVPermission(
        _ mediaType: AVMediaType,
        permission: CapturePermission,
        completion: @escaping (Bool) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                if !granted {
                    self.showPermissionSettingsAlert(title: permission.alertTitle, message: permission.deniedMessage)
                }
                completion(granted)
            }
        case .denied, .restricted:
            showPermissionSettingsAlert(title: permission.alertTitle, message: permission.deniedMessage)
            completion(false)
        @unknown default:
            showPermissionSettingsAlert(title: permission.alertTitle, message: permission.deniedMessage)
            completion(false)
        }
    }

    private func ensureLocationPermission(_ completion: @escaping (Bool) -> Void) {
        guard CLLocationManager.locationServicesEnabled() else {
            showPermissionSettingsAlert(
                title: CapturePermission.location.alertTitle,
                message: "Location Services are disabled. Please enable Location Services in Settings or turn GeoLoc off in Sensor Recorder settings."
            )
            completion(false)
            return
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            completion(true)
        case .notDetermined:
            pendingLocationPermissionCompletion = completion
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            showPermissionSettingsAlert(title: CapturePermission.location.alertTitle, message: CapturePermission.location.deniedMessage)
            completion(false)
        @unknown default:
            showPermissionSettingsAlert(title: CapturePermission.location.alertTitle, message: CapturePermission.location.deniedMessage)
            completion(false)
        }
    }

    private func ensureMotionPermission(_ completion: @escaping (Bool) -> Void) {
        guard CMMotionActivityManager.isActivityAvailable() else {
            completion(true)
            return
        }

        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized, .notDetermined:
            completion(true)
        case .denied, .restricted:
            showPermissionSettingsAlert(title: CapturePermission.motion.alertTitle, message: CapturePermission.motion.deniedMessage)
            completion(false)
        @unknown default:
            showPermissionSettingsAlert(title: CapturePermission.motion.alertTitle, message: CapturePermission.motion.deniedMessage)
            completion(false)
        }
    }

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private func startLocationRecording() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationRecorder = GeoLocationStreamRecorder(directory: outDirURL)
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    private func stopLocationRecording() {
        locationManager.stopUpdatingLocation()
        locationRecorder?.close()
        locationRecorder = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if let completion = pendingLocationPermissionCompletion {
            pendingLocationPermissionCompletion = nil
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                completion(true)
            case .denied, .restricted:
                showPermissionSettingsAlert(title: CapturePermission.location.alertTitle, message: CapturePermission.location.deniedMessage)
                completion(false)
            case .notDetermined:
                pendingLocationPermissionCompletion = completion
            @unknown default:
                showPermissionSettingsAlert(title: CapturePermission.location.alertTitle, message: CapturePermission.location.deniedMessage)
                completion(false)
            }
        }

        guard isRecording, locationRecorder != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            stopLocationRecording()
        case .notDetermined:
            break
        @unknown default:
            stopLocationRecording()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording, let locationRecorder = locationRecorder else { return }
        for location in locations {
            locationRecorder.append(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        os_log("Location update failed: %@", type: .error, error.localizedDescription)
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let message = error?.localizedDescription ?? "Unknown capture session error."
        os_log("Capture session runtime error: %@", type: .error, message)
        sessionQueue.async {
            if self.captureRecordingActive { self.reportRecordingFailure(message) }
            else if self.pendingPreviewCompletion != nil { self.previewConfigurationFailure = message }
            else { self.showError(msg: message) }
        }
    }

    @objc private func captureSessionWasInterrupted(_ notification: Notification) {
        sessionQueue.async {
            if self.captureRecordingActive { self.reportRecordingFailure("The capture session was interrupted") }
        }
    }

    @objc private func recordingAppDidEnterBackground() {
        guard isRecording || recordingTransition != .none else { return }
        if recordingBackgroundTask == .invalid {
            recordingBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish sensor recording") { [weak self] in
                self?.endRecordingBackgroundTask()
            }
        }
        // Camera interruption notifications are not guaranteed to arrive before
        // the app is suspended. Never leave a recording running across Home.
        sessionQueue.async {
            if self.captureRecordingActive || self.isRecording {
                self.reportRecordingFailure("Recording interrupted because the app entered the background")
            }
        }
    }

    @objc private func recordingAppDidBecomeActive() {
        guard let message = deferredRecordingError else { return }
        deferredRecordingError = nil
        showError(msg: message)
    }

    private func endRecordingBackgroundTask() {
        guard recordingBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(recordingBackgroundTask)
        recordingBackgroundTask = .invalid
    }

    @IBAction func startStopButtonPressed(_ sender: UIButton) {
        // Preview-only debug stage: keep recording disabled until dual preview is verified.
        guard !previewOnlyMode else { return }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func preparePreviewSession() {
        guard !isConfigured else { return }
        if pendingPreviewCompletion == nil { sanitizeRecorderSettingsForCurrentDevice() }
        setStatus("Preview")

        if isARKitMode {
            requestCameraAccess { granted in
                guard granted else { return }
                if self.recorderSettings.audioEnabled {
                    self.requestAudioAccess { _ in
                        self.sessionQueue.async {
                            self.configureARKitPreview()
                            DispatchQueue.main.async {
                                self.startStopButton.isEnabled = self.arSession != nil
                            }
                            self.setStatus(self.arSession != nil ? "ARKit Ready" : "ARKit failed")
                        }
                    }
                } else {
                    self.sessionQueue.async {
                        self.configureARKitPreview()
                        DispatchQueue.main.async {
                            self.startStopButton.isEnabled = self.arSession != nil
                        }
                        self.setStatus(self.arSession != nil ? "ARKit Ready" : "ARKit failed")
                    }
                }
            }
            return
        }

        let cameraEnabled = enabledCameraCount(in: recorderSettings) > 0 || recorderSettings.lidarDepthEnabled

        let configureAfterCameraPermission: () -> Void = {
            if self.previewDebugMode == .wideOnly {
                self.configureSingleCameraPreview()
                return
            }

            let configurePreview: (Bool) -> Void = { includeAudio in
                self.sessionQueue.async {
                    self.configurePreviewSession(includeAudio: includeAudio)
                    guard self.isConfigured else {
                        self.completePreviewPreparation(self.previewConfigurationFailure ?? "The selected capture configuration could not be applied.")
                        return
                    }
                    // Recheck after commitConfiguration: aggregate costs and
                    // negotiated formats may change when the graph is committed.
                    if let issue = self.activeStandardConfigurationIssue() {
                        self.isConfigured = false
                        self.completePreviewPreparation(issue)
                        return
                    }
                    if self.needsRunningCaptureSession {
                        self.session.startRunning()
                    }
                    let ready = self.needsRunningCaptureSession ? self.session.isRunning : true
                    if ready {
                        self.waitForPreviewSamples(session: self.session, deadline: Date().addingTimeInterval(5))
                    } else {
                        self.completePreviewPreparation("The capture session could not start with the selected configuration.")
                    }
                    self.setStatus(ready ? "Ready" : "Not running")
                }
            }

            if self.recorderSettings.audioEnabled {
                self.requestAudioAccess { audioGranted in
                    configurePreview(audioGranted)
                }
            } else {
                configurePreview(false)
            }
        }

        guard cameraEnabled else {
            configureAfterCameraPermission()
            return
        }

        requestCameraAccess { granted in
            guard granted else {
                self.completePreviewPreparation("Camera permission is required to validate these settings.")
                return
            }
            configureAfterCameraPermission()
        }
    }

    private func completePreviewPreparation(_ issue: String?) {
        DispatchQueue.main.async {
            self.startStopButton.isEnabled = issue == nil
            let completion = self.pendingPreviewCompletion
            self.pendingPreviewCompletion = nil
            if let completion { completion(issue) }
            else if let issue { self.showError(msg: issue) }
        }
    }

    private func waitForPreviewSamples(session expectedSession: AVCaptureSession, deadline: Date) {
        guard session === expectedSession else { return }
        if let issue = previewConfigurationFailure ?? activeStandardConfigurationIssue() {
            isConfigured = false
            expectedSession.stopRunning()
            completePreviewPreparation(issue)
            return
        }
        let cameras = [(RecordingCamera.wide, recorderSettings.wide), (.ultraWide, recorderSettings.ultraWide),
                       (.telephoto, recorderSettings.telephoto), (.front, recorderSettings.front)].filter { $0.1.enabled }
        if cameras.allSatisfy({ previewSampleSizes[$0.0] == $0.1.resolution }) {
            completePreviewPreparation(nil)
        } else if Date() < deadline {
            sessionQueue.asyncAfter(deadline: .now() + 0.05) { self.waitForPreviewSamples(session: expectedSession, deadline: deadline) }
        } else {
            let missing = cameras.filter { previewSampleSizes[$0.0] != $0.1.resolution }.map {
                "\($0.0.displayName): expected \($0.1.resolution), received \(previewSampleSizes[$0.0] ?? "no video frames")"
            }.joined(separator: "; ")
            isConfigured = false
            expectedSession.stopRunning()
            completePreviewPreparation("The cameras did not deliver the selected video format. \(missing)")
        }
    }

    private func configureSingleCameraPreview() {
        sessionQueue.async {
            let previewSession = AVCaptureSession()
            previewSession.beginConfiguration()
            previewSession.sessionPreset = .hd1280x720

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                previewSession.commitConfiguration()
                self.showError(msg: "Wide camera is unavailable.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard previewSession.canAddInput(input) else {
                    previewSession.commitConfiguration()
                    self.showError(msg: "Cannot add wide camera input.")
                    return
                }
                previewSession.addInput(input)
            } catch {
                previewSession.commitConfiguration()
                self.showError(msg: "Failed to open wide camera: \(error.localizedDescription)")
                return
            }

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            if previewSession.canAddOutput(videoOutput) {
                previewSession.addOutput(videoOutput)
                self.singleVideoOutput = videoOutput
            }

            previewSession.commitConfiguration()

            DispatchQueue.main.async {
                self.singlePreviewSession = previewSession
                self.singlePreviewLayer?.removeFromSuperlayer()
                self.singlePreviewView?.removeFromSuperview()
                self.diagnosticLayer?.removeFromSuperlayer()

                let diagnosticLayer = CALayer()
                diagnosticLayer.backgroundColor = UIColor.systemPink.withAlphaComponent(0.45).cgColor
                self.sceneView.layer.insertSublayer(diagnosticLayer, at: 0)
                self.diagnosticLayer = diagnosticLayer

                let previewView = CameraPreviewView(frame: self.sceneView.bounds)
                previewView.backgroundColor = UIColor.systemBlue
                previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                previewView.previewLayer.session = previewSession
                previewView.previewLayer.videoGravity = .resizeAspect
                previewView.previewLayer.backgroundColor = UIColor.systemBlue.cgColor
                self.sceneView.addSubview(previewView)
                self.singlePreviewView = previewView
                self.singlePreviewLayer = previewView.previewLayer
                self.layoutPreviewLayers()
                self.view.bringSubviewToFront(self.startStopButton.superview ?? self.startStopButton)
            }

            previewSession.startRunning()
            self.setStatus(previewSession.isRunning ? "Ready" : "Not running")
            self.isConfigured = true
        }
    }

    // MARK: - ARKit Session Management

    private func configureARKitPreview() {
        guard !isConfigured else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            os_log("ARKit world tracking is not supported on this device.", type: .error)
            showError(msg: "ARKit is not supported on this device.")
            return
        }

        let arSession = ARSession()
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.providesAudioData = false
        config.isLightEstimationEnabled = false
        config.planeDetection = []

        let settings = recorderSettings.arkitCamera
        let selectedFormat = pickARKitVideoFormat(for: config, resolution: settings.resolution, frameRate: settings.frameRate)
        if let format = selectedFormat {
            config.videoFormat = format
        }

        if recorderSettings.lidarDepthEnabled, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        // Configure device BEFORE running the session so focus/exposure are set from the start
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            self.arkitCaptureDevice = device
            do {
                try configureARKitDeviceForPreview(device, settings: settings)
                self.arkitDeviceConfigured = true
            } catch {
                os_log("Failed to pre-configure ARKit capture device: %@", type: .error, error.localizedDescription)
                self.arkitDeviceConfigured = false
            }
        }

        arSession.delegate = self
        arSession.delegateQueue = arkitFrameQueue
        arSession.run(config)

        self.arSession = arSession
        self.arkitConfiguration = config
        self.isConfigured = true

        // Set up audio capture on a dedicated session for ARKit mode
        if recorderSettings.audioEnabled {
            configureARKitAudioCapture()
        }

        DispatchQueue.main.async {
            let displayLayer = self.makeDisplayLayer(for: "arkit")
            self.sceneView.layer.insertSublayer(displayLayer, at: 0)
            self.arkitDisplayLayer = displayLayer
            self.layoutPreviewLayers()
            self.view.bringSubviewToFront(self.startStopButton.superview ?? self.startStopButton)
        }

        let activeDimensions = selectedFormat.map {
            CGSize(width: $0.imageResolution.width, height: $0.imageResolution.height)
        } ?? CGSize(width: 1920, height: 1440)
        os_log(
            "Configured ARKit camera active %dx%d requested %@",
            Int(activeDimensions.width),
            Int(activeDimensions.height),
            settings.resolution
        )
    }

    /// Set up a dedicated AVCaptureSession for audio capture in ARKit mode.
    /// ARKit uses ARSession (not AVCaptureSession), so audio needs its own session.
    private func configureARKitAudioCapture() {
        guard arkitAudioSession == nil else { return }
        let audioSession = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .audio) else {
            os_log("Audio input unavailable for ARKit mode.", type: .error)
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard audioSession.canAddInput(input) else {
                os_log("Cannot add audio input to ARKit audio session.", type: .error)
                return
            }
            audioSession.addInput(input)

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            guard audioSession.canAddOutput(output) else {
                os_log("Cannot add audio output to ARKit audio session.", type: .error)
                return
            }
            audioSession.addOutput(output)
            self.audioOutput = output

            configureAudioSessionForCapture()
            self.arkitAudioSession = audioSession
            audioSession.startRunning()
            os_log("ARKit audio session started.", type: .info)
        } catch {
            os_log("Failed to configure ARKit audio capture: %@", type: .error, error.localizedDescription)
        }
    }

    private func pickARKitVideoFormat(
        for config: ARWorldTrackingConfiguration,
        resolution: String,
        frameRate: String
    ) -> ARConfiguration.VideoFormat? {
        let target = resolutionSize(from: resolution) ?? CGSize(width: 1920, height: 1440)
        let targetWidth = Int(target.width)
        let targetHeight = Int(target.height)
        let formats: [ARConfiguration.VideoFormat] = ARWorldTrackingConfiguration.supportedVideoFormats

        let targetFPS = Int(clampedFrameRate(from: frameRate).rounded())
        let exactMatches = formats.filter { fmt in
            Int(fmt.imageResolution.width) == targetWidth && Int(fmt.imageResolution.height) == targetHeight
        }
        if let exactMatch = exactMatches.min(by: {
            abs($0.framesPerSecond - targetFPS) < abs($1.framesPerSecond - targetFPS)
        }) {
            return exactMatch
        }

        // Otherwise pick the closest resolution, then the closest actual frame rate.
        return formats.min { lhs, rhs in
            let lhsArea = Int(lhs.imageResolution.width) * Int(lhs.imageResolution.height)
            let rhsArea = Int(rhs.imageResolution.width) * Int(rhs.imageResolution.height)
            let lhsDist = abs(lhsArea - targetWidth * targetHeight)
            let rhsDist = abs(rhsArea - targetWidth * targetHeight)
            if lhsDist != rhsDist { return lhsDist < rhsDist }
            return abs(lhs.framesPerSecond - targetFPS) < abs(rhs.framesPerSecond - targetFPS)
        }
    }

    private func configureARKitDeviceForPreview(_ device: AVCaptureDevice, settings: CameraCaptureSettings) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        applyAutoExposurePolicy(to: device, settings: settings)

        if settings.autoFocus {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        } else if device.isFocusModeSupported(.locked) {
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(
                    lensPosition: Float(clampedLensPosition(settings.fixedFocusLensPosition, fallback: defaultARKitFixedFocusLensPosition)),
                    completionHandler: nil
                )
            } else {
                device.focusMode = .locked
            }
        }
    }

    private func arkitActiveResolution() -> CGSize {
        let settings = recorderSettings.arkitCamera
        if let format = arkitConfiguration?.videoFormat {
            return format.imageResolution
        }
        return resolutionSize(from: settings.resolution) ?? CGSize(width: 1920, height: 1440)
    }

    private func arkitActiveFrameRate() -> Double {
        if let format = arkitConfiguration?.videoFormat {
            return Double(format.framesPerSecond)
        }
        return clampedFrameRate(from: recorderSettings.arkitCamera.frameRate)
    }

    private func tearDownARKitSession() {
        arSession?.pause()
        arSession?.delegate = nil
        arSession = nil
        arkitConfiguration = nil
        arkitRecorder = nil
        arkitDisplayLayer?.removeFromSuperlayer()
        arkitDisplayLayer = nil
        arkitFrameCount = 0
        arkitPreviewEnqueuePending = false
        arkitLastRecordSlot = nil
        arkitDeviceConfigured = false
        arkitCaptureDevice = nil
        arkitTrackingState = .notAvailable
        arkitAudioSession?.stopRunning()
        arkitAudioSession = nil
        audioOutput = nil
        isConfigured = false
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        arkitFrameCount += 1
        arkitTrackingState = frame.camera.trackingState

        // Ensure we have a reference to the capture device
        if arkitCaptureDevice == nil {
            arkitCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }

        // Re-apply focus/exposure if ARKit has overridden them
        if let device = arkitCaptureDevice {
            let settings = recorderSettings.arkitCamera
            let needsFocusLock = !settings.autoFocus && device.focusMode != .locked
            let needsExposureLock = !isAutoExposureEnabled(for: settings) && device.exposureMode != .locked
            if needsFocusLock || needsExposureLock {
                try? configureARKitDeviceForPreview(device, settings: settings)
            }
        }

        let pts = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000)

        if isRecording {
            let pixelBuffer = frame.capturedImage
            let recordSlot = arkitRecordingSlotIfFrameShouldBeWritten(pts)

            if let recordSlot = recordSlot {
                arkitRecorder?.append(
                    pixelBuffer: pixelBuffer,
                    presentationTime: pts,
                    camera: frame.camera,
                    recordSlot: recordSlot
                )
            }

            // Process ARKit scene depth if available and recording
            if let sceneDepth = frame.sceneDepth,
               let depthRecorder = lidarDepthRecorder,
               arkitDepthBackpressure.wait(timeout: .now()) == .success {
                let sensorSec = CMTimeGetSeconds(pts)
                let depthMap = sceneDepth.depthMap
                let intrinsics = frame.camera.intrinsics
                let imageResolution = frame.camera.imageResolution
                arkitDepthQueue.async { [weak self] in
                    defer { self?.arkitDepthBackpressure.signal() }
                    depthRecorder.appendARKitDepthMap(
                        depthMap,
                        intrinsics: intrinsics,
                        imageResolution: imageResolution,
                        sensorSec: sensorSec
                    )
                    self?.lidarDepthFrameCount += 1
                    if self?.firstDepthSensorSec == nil {
                        self?.firstDepthSensorSec = sensorSec
                    }
                    self?.latestDepthSensorSec = sensorSec
                }
            }
        }

        enqueueARKitPreview(frame.capturedImage, pts: pts)

        guard arkitFrameCount % 30 == 0 else { return }
        setStatus("ARKit Frames")
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        os_log("ARSession failed: %@", type: .error, error.localizedDescription)
        DispatchQueue.main.async {
            self.showError(msg: "ARKit session error: \(error.localizedDescription)")
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        os_log("ARSession interrupted", type: .info)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        os_log("ARSession interruption ended", type: .info)
    }

    private func enqueueARKitPreview(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let displayLayer = arkitDisplayLayer else { return }
        guard !arkitPreviewEnqueuePending else { return }
        arkitPreviewEnqueuePending = true

        DispatchQueue.main.async { [weak self, weak displayLayer] in
            defer {
                self?.arkitPreviewEnqueuePending = false
            }
            guard let displayLayer else { return }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            guard displayLayer.isReadyForMoreMediaData else { return }

            var formatDesc: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard let formatDesc = formatDesc else { return }

            var timingInfo = CMSampleTimingInfo(
                duration: CMTimeMake(value: 1, timescale: 30),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            )
            if let sampleBuffer = sampleBuffer {
                displayLayer.enqueue(sampleBuffer)
            }
        }
    }

    private func arkitRecordingSlotIfFrameShouldBeWritten(_ presentationTime: CMTime) -> Int64? {
        let sensorSec = CMTimeGetSeconds(presentationTime)
        guard sensorSec.isFinite else { return nil }

        if recordingGridOriginSec == nil {
            recordingGridOriginSec = sensorSec
        }
        guard let originSec = recordingGridOriginSec else { return nil }

        let targetFPS = targetRecordingFrameRate(for: recorderSettings.arkitCamera)
        let slot = Int64((max(sensorSec - originSec, 0) * targetFPS).rounded())
        guard arkitLastRecordSlot != slot else { return nil }
        arkitLastRecordSlot = slot
        return slot
    }

    private struct StandardVideoBranch {
        let key: String
        let camera: RecordingCamera
        let output: AVCaptureVideoDataOutput
        let device: AVCaptureDevice
    }

    private func standardVideoBranches() -> [StandardVideoBranch] {
        var result: [StandardVideoBranch] = []
        if let output = widePreviewOutput, let device = wideDevice { result.append(.init(key: device.uniqueID, camera: .wide, output: output, device: device)) }
        if let output = ultraWidePreviewOutput, let device = ultraWideDevice { result.append(.init(key: device.uniqueID, camera: .ultraWide, output: output, device: device)) }
        if let output = telephotoPreviewOutput, let device = telephotoDevice { result.append(.init(key: device.uniqueID, camera: .telephoto, output: output, device: device)) }
        if let output = frontPreviewOutput, let device = frontDevice { result.append(.init(key: device.uniqueID, camera: .front, output: output, device: device)) }
        return result
    }

    private func configureStandardSynchronizer() {
        standardSynchronizer?.setDelegate(nil, queue: nil)
        standardSynchronizer = nil
        let hardware = multiCameraGraph?.hardwareSyncCameras ?? []
        let outputs = standardVideoBranches().filter { hardware.contains($0.camera) }.map(\.output)
        guard outputs.count > 1 else { return }
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: outputs)
        synchronizer.setDelegate(self, queue: sessionQueue)
        standardSynchronizer = synchronizer
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard synchronizer === standardSynchronizer else { return }
        let hardware = multiCameraGraph?.hardwareSyncCameras ?? []
        let branches = standardVideoBranches().filter { hardware.contains($0.camera) }
        guard let primary = branches.first,
              collection.synchronizedData(for: primary.output) != nil else { return }
        var samples: [(StandardVideoBranch, CMSampleBuffer)] = []
        var missing: [String] = []
        var dropDetails: [String] = []
        for branch in branches {
            guard let data = collection.synchronizedData(for: branch.output) as? AVCaptureSynchronizedSampleBufferData else {
                missing.append(branch.camera.rawValue)
                dropDetails.append("\(branch.camera.rawValue): absent")
                continue
            }
            guard !data.sampleBufferWasDropped, CMSampleBufferDataIsReady(data.sampleBuffer) else {
                missing.append(branch.camera.rawValue)
                dropDetails.append("\(branch.camera.rawValue): reason=\(data.droppedReason.rawValue), pts=\(CMTimeGetSeconds(data.timestamp))")
                continue
            }
            samples.append((branch, data.sampleBuffer))
            // The synchronizer owns the output delegates. Reuse only preview
            // bookkeeping here; recording is dispatched as a complete group below.
            switch branch.camera {
            case .wide: wideFrameCount += 1; enqueuePreview(data.sampleBuffer, on: wideDisplayLayer, camera: .wide)
            case .ultraWide: ultraWideFrameCount += 1; enqueuePreview(data.sampleBuffer, on: ultraWideDisplayLayer, camera: .ultraWide)
            case .telephoto: telephotoFrameCount += 1; enqueuePreview(data.sampleBuffer, on: telephotoDisplayLayer, camera: .telephoto)
            case .front: frontFrameCount += 1; enqueuePreview(data.sampleBuffer, on: frontDisplayLayer, camera: .front)
            }
        }
        if samples.first?.0.camera == .wide && wideFrameCount % 30 == 0 {
            setStatus(recorderSettings.front.enabled ? "Partial hardware sync" : "Hardware sync")
        }
        guard captureRecordingActive else { return }
        guard samples.allSatisfy({ sensorSeconds(for: CMSampleBufferGetPresentationTimeStamp($0.1)) >= (recordingAdmissionSensorSec ?? .infinity) }) else { return }
        guard missing.isEmpty else {
            // Do not classify initial stream warm-up as an in-recording loss.
            guard synchronizationGroup > 0 else { return }
            synchronizationWriter?.writeLine("# dropped_group,\(synchronizationGroup),missing,\(missing.joined(separator: "+"))")
            synchronizationDroppedGroups += 1
            synchronizationGroup += 1
            reportRecordingFailure("A hardware-synchronized frame group is incomplete: \(dropDetails.joined(separator: "; "))")
            return
        }
        if synchronizationOrigin == nil {
            stageInitialRecordingSamples(samples.map { ($0.0.camera, $0.1) })
        } else { writeHardwareSynchronizedGroup(samples) }
    }

    private func stageInitialRecordingSamples(_ samples: [(RecordingCamera, CMSampleBuffer)]) {
        // This is capture warm-up, before the recording epoch exists. Keep only
        // the latest initial sample per camera; once every stream is present,
        // admit all subsequent frames independently without a shared time grid.
        for (camera, sample) in samples { initialRecordingSamples[camera] = sample }
        let cameras = enabledPhysicalCameras(recorderSettings)
        guard cameras.allSatisfy({ initialRecordingSamples[$0] != nil }) else { return }
        synchronizationOrigin = initialRecordingSamples.values.map(CMSampleBufferGetPresentationTimeStamp).min { CMTimeCompare($0, $1) < 0 }
        synchronizationOriginSensorSec = synchronizationOrigin.map { sensorSeconds(for: $0) }
        let hardware = multiCameraGraph?.hardwareSyncCameras ?? []
        if hardware.count > 1 {
            let group = standardVideoBranches().filter { hardware.contains($0.camera) }.compactMap { branch in
                initialRecordingSamples[branch.camera].map { (branch, $0) }
            }
            writeHardwareSynchronizedGroup(group)
        }
        for camera in cameras where !hardware.contains(camera) {
            if let sample = initialRecordingSamples[camera] { appendRecordingSampleDirect(sample, camera: camera) }
        }
        initialRecordingSamples.removeAll()
    }

    private func writeHardwareSynchronizedGroup(_ samples: [(StandardVideoBranch, CMSampleBuffer)]) {
        let seconds = samples.map { sensorSeconds(for: CMSampleBufferGetPresentationTimeStamp($0.1)) }
        let skew = (seconds.max() ?? 0) - (seconds.min() ?? 0)
        synchronizationMaxSkew = max(synchronizationMaxSkew, skew)
        guard skew <= 0.001 else { reportRecordingFailure("Hardware constituent timestamps differ by more than 1 ms"); return }
        var row = [String(synchronizationGroup), String(format: "%.9f", seconds.first ?? 0)]
        for camera in [RecordingCamera.wide, .ultraWide, .telephoto, .front] {
            if let index = samples.firstIndex(where: { $0.0.camera == camera }) { row.append(String(format: "%.9f", seconds[index])) }
            else { row.append("") }
        }
        row.append(String(format: "%.9f", skew))
        synchronizationWriter?.writeLine(row.joined(separator: ","))
        for (index, entry) in samples.enumerated() {
            appendRecordingSampleDirect(entry.1, camera: entry.0.camera, recordSlot: synchronizationGroup, sensorSec: seconds[index])
        }
        synchronizationGroup += 1
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let audioOutput = audioOutput, output === audioOutput {
            if captureRecordingActive || (isARKitMode && isRecording) {
                appendAudioSample(sampleBuffer)
            }
            return
        }

        if let wideOutput = widePreviewOutput, output === wideOutput {
            wideFrameCount += 1
            if captureRecordingActive || (isARKitMode && isRecording) {
                appendRecordingSample(sampleBuffer, camera: .wide)
            }
            enqueuePreview(sampleBuffer, on: wideDisplayLayer, camera: .wide)
            guard wideFrameCount % 30 == 0 else { return }
            setStatus("Frames")
            return
        }

        if let ultraWideOutput = ultraWidePreviewOutput, output === ultraWideOutput {
            ultraWideFrameCount += 1
            if captureRecordingActive || (isARKitMode && isRecording) {
                appendRecordingSample(sampleBuffer, camera: .ultraWide)
            }
            enqueuePreview(sampleBuffer, on: ultraWideDisplayLayer, camera: .ultraWide)
            guard ultraWideFrameCount % 30 == 0 else { return }
            setStatus("Frames")
            return
        }

        if let telephotoOutput = telephotoPreviewOutput, output === telephotoOutput {
            telephotoFrameCount += 1
            if captureRecordingActive || (isARKitMode && isRecording) {
                appendRecordingSample(sampleBuffer, camera: .telephoto)
            }
            enqueuePreview(sampleBuffer, on: telephotoDisplayLayer, camera: .telephoto)
            guard telephotoFrameCount % 30 == 0 else { return }
            setStatus("Frames")
            return
        }

        if let frontOutput = frontPreviewOutput, output === frontOutput {
            frontFrameCount += 1
            if captureRecordingActive || (isARKitMode && isRecording) {
                appendRecordingSample(sampleBuffer, camera: .front)
            }
            enqueuePreview(sampleBuffer, on: frontDisplayLayer, camera: .front)
            guard frontFrameCount % 30 == 0 else { return }
            setStatus("Frames")
            return
        }

        singleFrameCount += 1
        guard singleFrameCount % 30 == 0 else { return }
        setStatus("Frames \(singleFrameCount)")
    }

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        guard output === lidarDepthOutput else { return }
        lidarDepthFrameCount += 1
        let sensorSec = sensorSeconds(for: timestamp)
        if firstDepthSensorSec == nil {
            firstDepthSensorSec = sensorSec
        }
        latestDepthSensorSec = sensorSec
        if isRecording {
            lidarDepthRecorder?.append(depthData: depthData, sensorSec: sensorSec)
        }
        if let image = depthPreviewImage(from: depthData) {
            DispatchQueue.main.async {
                self.depthPreviewView?.image = image
            }
        }
        guard lidarDepthFrameCount % 15 == 0 else { return }
        setStatus("Depth")
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        let sessionClock = captureSessionClock()
        if let audioSample = copySampleBuffer(sampleBuffer) {
            audioRecorder?.append(audioSample, sessionClock: sessionClock)
        }
        guard embedAudioInCameraMP4 else { return }
        if let wideAudioSample = copySampleBuffer(sampleBuffer) {
            wideRecorder?.appendAudio(wideAudioSample)
        }
        if let ultraAudioSample = copySampleBuffer(sampleBuffer) {
            ultraWideRecorder?.appendAudio(ultraAudioSample)
        }
        if let telephotoAudioSample = copySampleBuffer(sampleBuffer) {
            telephotoRecorder?.appendAudio(telephotoAudioSample)
        }
        if let frontAudioSample = copySampleBuffer(sampleBuffer) {
            frontRecorder?.appendAudio(frontAudioSample)
        }
    }

    private func copySampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var copiedSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copiedSampleBuffer
        )
        guard status == noErr else {
            os_log("Failed to copy audio sample buffer: %d", type: .error, status)
            return nil
        }
        return copiedSampleBuffer
    }

    private func noteCaptureCadence(_ sample: CMSampleBuffer, camera: RecordingCamera) {
        if let image = CMSampleBufferGetImageBuffer(sample) {
            previewSampleSizes[camera] = "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))"
        }
        let time = sensorSeconds(for: CMSampleBufferGetPresentationTimeStamp(sample))
        guard time.isFinite else { return }
        var state = captureCadence[camera] ?? (time, time, 0, time - 1)
        state.latest = time
        state.count += 1
        captureCadence[camera] = state
        if state.count > 1 && time - state.published >= 0.5 {
            let rate = Double(state.count - 1) / max(time - state.first, 0.001)
            state.published = time
            captureCadence[camera] = state
            let image = CMSampleBufferGetImageBuffer(sample)
            let size = image.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" }
            DispatchQueue.main.async {
                self.measuredCameraFPS[camera] = rate
                if let size { self.measuredCameraSizes[camera] = size }
                self.refreshOverlayStatus()
            }
        }
    }

    @objc private func recheckCaptureCapabilities() {
        sessionQueue.async {
            self.validatedMultiCameraFormats.removeAll()
            DispatchQueue.main.async { self.updateCameraResolutionMenus() }
        }
    }

    private func reportRecordingFailure(_ reason: String) {
        guard recordingFailure == nil else { return }
        recordingFailure = reason
        captureRecordingActive = false
        writeCaptureMetaJSON(state: "failed")
        DispatchQueue.main.async {
            if self.isRecording { self.stopRecording() }
            let message = "Recording stopped without changing its configuration. \(reason)"
            if UIApplication.shared.applicationState == .background { self.deferredRecordingError = message }
            else { self.showError(msg: message) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard captureRecordingActive else { return }
        let seconds = sensorSeconds(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if let admission = recordingAdmissionSensorSec, seconds.isFinite && seconds < admission { return }
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        reportRecordingFailure("AVFoundation dropped a video sample: \(reason.map { String(describing: $0) } ?? "unspecified")")
    }

    private func appendRecordingSample(_ sampleBuffer: CMSampleBuffer, camera: RecordingCamera) {
        guard sensorSeconds(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) >= (recordingAdmissionSensorSec ?? .infinity) else { return }
        if enabledCameraCount(in: recorderSettings) > 1 && synchronizationOrigin == nil {
            stageInitialRecordingSamples([(camera, sampleBuffer)])
        } else { appendRecordingSampleDirect(sampleBuffer, camera: camera) }
    }

    private func appendRecordingSampleDirect(_ sampleBuffer: CMSampleBuffer, camera: RecordingCamera, recordSlot: Int64? = nil, sensorSec: TimeInterval? = nil) {
        let recorder: CameraStreamRecorder?
        let physical: AVCaptureDevice?
        switch camera {
        case .wide: recorder = wideRecorder; physical = wideDevice
        case .ultraWide: recorder = ultraWideRecorder; physical = ultraWideDevice
        case .telephoto: recorder = telephotoRecorder; physical = telephotoDevice
        case .front: recorder = frontRecorder; physical = frontDevice
        }
        recorder?.append(sampleBuffer, device: multiCameraGraph?.controllers[camera] ?? physical,
                         sessionClock: captureSessionClock(), recordSlot: recordSlot, sessionOrigin: synchronizationOrigin, sensorSec: sensorSec)
    }

    private func resetRecordingSamplingState() {
        recordingGridOriginSec = nil
        initialRecordingSamples.removeAll()
    }

    private func enqueuePreview(_ sampleBuffer: CMSampleBuffer, on displayLayer: AVSampleBufferDisplayLayer?, camera: RecordingCamera) {
        noteCaptureCadence(sampleBuffer, camera: camera)
        guard let displayLayer = displayLayer else { return }
        guard !isPreviewEnqueuePending(camera) else { return }
        setPreviewEnqueuePending(true, camera: camera)

        DispatchQueue.main.async { [weak self, weak displayLayer] in
            defer {
                self?.sessionQueue.async {
                    self?.setPreviewEnqueuePending(false, camera: camera)
                }
            }
            guard let displayLayer else { return }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            guard displayLayer.isReadyForMoreMediaData else { return }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func isPreviewEnqueuePending(_ camera: RecordingCamera) -> Bool {
        switch camera {
        case .wide:
            return widePreviewEnqueuePending
        case .ultraWide:
            return ultraWidePreviewEnqueuePending
        case .telephoto:
            return telephotoPreviewEnqueuePending
        case .front:
            return frontPreviewEnqueuePending
        }
    }

    private func setPreviewEnqueuePending(_ pending: Bool, camera: RecordingCamera) {
        switch camera {
        case .wide:
            widePreviewEnqueuePending = pending
        case .ultraWide:
            ultraWidePreviewEnqueuePending = pending
        case .telephoto:
            telephotoPreviewEnqueuePending = pending
        case .front:
            frontPreviewEnqueuePending = pending
        }
    }

    private func captureSessionClock() -> CMClock? {
        // Single-camera outputs also use the session clock, which may differ from host time.
        session.synchronizationClock
    }

    private func sensorSeconds(for sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return sensorSeconds(for: presentationTime)
    }

    private func sensorSeconds(for presentationTime: CMTime) -> TimeInterval {
        guard let sessionClock = captureSessionClock() else {
            return CMTimeGetSeconds(presentationTime)
        }
        let sensorTime = CMSyncConvertTime(presentationTime, from: sessionClock, to: CMClockGetHostTimeClock())
        return CMTimeGetSeconds(sensorTime)
    }

    private func depthPreviewImage(from depthData: AVDepthData) -> UIImage? {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let pixelBuffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        var minDepth = Float.greatestFiniteMagnitude
        var maxDepth: Float = 0
        for row in 0..<height {
            let rowBase = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for column in 0..<width {
                let value = rowBase[column]
                if value.isFinite && value > 0 {
                    minDepth = min(minDepth, value)
                    maxDepth = max(maxDepth, value)
                }
            }
        }
        guard minDepth.isFinite, maxDepth > minDepth else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let range = max(maxDepth - minDepth, 0.001)
        for row in 0..<height {
            let rowBase = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for column in 0..<width {
                let value = rowBase[column]
                let pixelIndex = (row * width + column) * 4
                guard value.isFinite, value > 0 else {
                    rgba[pixelIndex + 3] = 255
                    continue
                }
                let nearWarm = 1.0 - min(max(Double((value - minDepth) / range), 0.0), 1.0)
                rgba[pixelIndex + 0] = UInt8(255.0 * nearWarm)
                rgba[pixelIndex + 1] = UInt8(255.0 * (1.0 - abs(nearWarm - 0.5) * 2.0))
                rgba[pixelIndex + 2] = UInt8(255.0 * (1.0 - nearWarm))
                rgba[pixelIndex + 3] = 255
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func enabledPhysicalCameras(_ settings: RecorderSettings) -> Set<PhysicalCamera> {
        Set([(PhysicalCamera.wide, settings.wide.enabled), (.ultraWide, settings.ultraWide.enabled),
             (.telephoto, settings.telephoto.enabled), (.front, settings.front.enabled)].filter { $0.1 }.map { $0.0 })
    }

    private func multiCameraRequest(_ settings: RecorderSettings, includeAudio: Bool? = nil) -> MultiCameraCaptureGraph.Request? {
        let cameras = enabledPhysicalCameras(settings)
        guard cameras.count > 1, !settings.lidarDepthEnabled else { return nil }
        guard let reference = [settings.wide, settings.ultraWide, settings.telephoto, settings.front].first(where: \.enabled) else { return nil }
        return .init(cameras: cameras, resolution: reference.resolution, fps: clampedFrameRate(from: reference.frameRate),
                     automaticExposure: isAutoExposureEnabled(for: reference), maxExposureSeconds: maxExposureDurationSeconds(for: reference),
                     automaticFocus: reference.autoFocus, audioEnabled: includeAudio ?? settings.audioEnabled)
    }

    private func multiCameraProfileKey(_ request: MultiCameraCaptureGraph.Request) -> String {
        request.cameras.map(\.rawValue).sorted().joined(separator: "+") + ":\(request.resolution):\(request.fps):\(request.audioEnabled)"
    }

    private func configureMultiCameraPreview(includeAudio: Bool) {
        guard let request = multiCameraRequest(recorderSettings, includeAudio: includeAudio) else {
            previewConfigurationFailure = "This combination cannot use the requested multi-camera capture path."
            return
        }
        do {
            let graph = try MultiCameraCaptureGraph.make(request, frozenFormats: validatedMultiCameraFormats[multiCameraProfileKey(request)])
            multiCameraGraph = graph
            session = graph.session
            observeSessionRuntimeErrorsIfNeeded()
            if let output = graph.audioOutput {
                configureAudioSessionForCapture()
                output.setSampleBufferDelegate(self, queue: sessionQueue)
                audioOutput = output
            }
            for (camera, output) in graph.outputs {
                guard let device = graph.sourceDevices[camera],
                      let port = graph.ports[camera] else { continue }
                output.setSampleBufferDelegate(self, queue: sessionQueue)
                switch camera {
                case .wide: wideDevice = device; widePreviewOutput = output; wideVideoPort = port
                case .ultraWide: ultraWideDevice = device; ultraWidePreviewOutput = output; ultraWideVideoPort = port
                case .telephoto: telephotoDevice = device; telephotoPreviewOutput = output; telephotoVideoPort = port
                case .front: frontDevice = device; frontPreviewOutput = output; frontVideoPort = port
                }
                DispatchQueue.main.async {
                    let name = camera == .ultraWide ? "ultrawide" : camera.rawValue
                    let layer = self.makeDisplayLayer(for: name)
                    self.sceneView.layer.insertSublayer(layer, at: 0)
                    switch camera {
                    case .wide: self.wideDisplayLayer = layer
                    case .ultraWide: self.ultraWideDisplayLayer = layer
                    case .telephoto: self.telephotoDisplayLayer = layer
                    case .front: self.frontDisplayLayer = layer
                    }
                    self.layoutPreviewLayers()
                }
            }
            configureStandardSynchronizer()
            configuredCameraFormats = graph.formats
            isConfigured = true
        } catch { previewConfigurationFailure = error.localizedDescription }
    }

    private func configurePreviewSession(includeAudio: Bool) {
        guard !isConfigured else { return }
        if pendingPreviewCompletion == nil { sanitizeRecorderSettingsForCurrentDevice() }
        previewConfigurationFailure = nil

        if let issue = standardConfigurationIssue(recorderSettings) {
            previewConfigurationFailure = issue
            return
        }

        if enabledCameraCount(in: recorderSettings) > 1 {
            configureMultiCameraPreview(includeAudio: includeAudio)
            return
        }
        observeSessionRuntimeErrorsIfNeeded()

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        configureSessionPresetForActiveFormats()

        let wideEnabled = recorderSettings.wide.enabled
        let ultraWideEnabled = recorderSettings.ultraWide.enabled
        let telephotoEnabled = recorderSettings.telephoto.enabled
        let frontEnabled = recorderSettings.front.enabled
        let multiCameraCapture = enabledCameraCount(in: recorderSettings) > 1 && session is AVCaptureMultiCamSession

        if (previewDebugMode == .wideOnly || previewDebugMode == .dual) && wideEnabled {
            guard configurePreviewCamera(
                deviceType: recorderSettings.lidarDepthEnabled ? .builtInLiDARDepthCamera : .builtInWideAngleCamera,
                position: .back,
                cameraName: "wide",
                previewIndex: 0,
                settings: recorderSettings.wide,
                requiresMultiCamFormat: multiCameraCapture
            ) else {
                os_log("Failed to configure wide camera.", type: .error)
                previewConfigurationFailure = "Wide camera cannot use the selected configuration. No formats were reduced."
                return
            }
        }

        if (previewDebugMode == .ultraWideOnly || previewDebugMode == .dual) && ultraWideEnabled {
            guard configurePreviewCamera(
                deviceType: .builtInUltraWideCamera,
                position: .back,
                cameraName: "ultrawide",
                previewIndex: 1,
                settings: recorderSettings.ultraWide,
                requiresMultiCamFormat: multiCameraCapture
            ) else {
                os_log("Failed to configure ultra-wide camera.", type: .error)
                previewConfigurationFailure = "Ultra-wide camera cannot use the selected configuration. No formats were reduced."
                return
            }
        }

        if previewDebugMode == .dual && telephotoEnabled {
            if !configurePreviewCamera(
                deviceType: .builtInTelephotoCamera,
                position: .back,
                cameraName: "telephoto",
                previewIndex: 2,
                settings: recorderSettings.telephoto,
                requiresMultiCamFormat: multiCameraCapture
            ) {
                previewConfigurationFailure = "Telephoto cannot run with the selected camera configuration."
                return
            }
        }

        if previewDebugMode == .dual && frontEnabled {
            if !configurePreviewCamera(
                deviceType: .builtInWideAngleCamera,
                position: .front,
                cameraName: "front",
                previewIndex: 3,
                settings: recorderSettings.front,
                requiresMultiCamFormat: multiCameraCapture
            ) {
                previewConfigurationFailure = "Front camera cannot run with the selected camera configuration."
                return
            }
        }

        if recorderSettings.lidarDepthEnabled {
            configureLiDARDepthCaptureIfNeeded()
            if previewConfigurationFailure != nil { return }
        }

        if includeAudio {
            configureAudioSessionForCapture()
            configureAudioCapture()
        }

        if let issue = activeStandardConfigurationIssue() {
            previewConfigurationFailure = issue
            return
        }
        configureStandardSynchronizer()
        configuredCameraFormats = Dictionary(uniqueKeysWithValues: standardVideoBranches().map { ($0.key, $0.device.activeFormat) })
        isConfigured = true
        setStatus(enabledCameraCount(in: recorderSettings) > 1 ? "multi preview" : "single preview")
    }

    private func configureLiDARDepthCaptureIfNeeded() {
        guard lidarDepthOutput == nil else { return }
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            previewConfigurationFailure = "LiDAR depth camera is unavailable."
            os_log("LiDAR depth camera unavailable.", type: .error)
            return
        }

        do {
            try configureLiDARDeviceForDepth(device)
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                os_log("Cannot add LiDAR depth input.", type: .error)
                previewConfigurationFailure = "LiDAR cannot run with the selected camera combination."
                return
            }
            session.addInputWithNoConnections(input)

            guard let depthPort = input.ports.first(where: { $0.mediaType == .depthData }) else {
                os_log("LiDAR input has no depth port.", type: .error)
                session.removeInput(input)
                previewConfigurationFailure = "The selected LiDAR input has no depth port."
                return
            }

            let output = AVCaptureDepthDataOutput()
            output.isFilteringEnabled = true
            output.alwaysDiscardsLateDepthData = true
            output.setDelegate(self, callbackQueue: sessionQueue)
            guard session.canAddOutput(output) else {
                os_log("Cannot add LiDAR depth output.", type: .error)
                session.removeInput(input)
                previewConfigurationFailure = "The selected camera combination cannot provide a depth output."
                return
            }
            session.addOutputWithNoConnections(output)

            let connection = AVCaptureConnection(inputPorts: [depthPort], output: output)
            guard session.canAddConnection(connection) else {
                os_log("Cannot add LiDAR depth connection.", type: .error)
                session.removeOutput(output)
                session.removeInput(input)
                previewConfigurationFailure = "The selected camera combination cannot connect its depth output."
                return
            }
            session.addConnection(connection)

            lidarDevice = device
            lidarDepthPort = depthPort
            lidarDepthOutput = output
            DispatchQueue.main.async {
                self.installDepthPreviewViewIfNeeded()
                self.layoutPreviewLayers()
                self.refreshOverlayStatus()
            }
        } catch {
            previewConfigurationFailure = "Could not apply the selected LiDAR formats: \(error.localizedDescription)"
            os_log("Failed to configure LiDAR depth: %@", type: .error, error.localizedDescription)
        }
    }

    private func configureDepthOutputIfNeeded(input: AVCaptureDeviceInput, device: AVCaptureDevice) {
        guard lidarDepthOutput == nil else { return }
        guard let depthPort = input.ports.first(where: { $0.mediaType == .depthData }) else {
            os_log("LiDAR input has no depth port.", type: .error)
            return
        }

        let output = AVCaptureDepthDataOutput()
        output.isFilteringEnabled = true
        output.alwaysDiscardsLateDepthData = true
        output.setDelegate(self, callbackQueue: sessionQueue)
        guard session.canAddOutput(output) else {
            os_log("Cannot add LiDAR depth output.", type: .error)
            return
        }
        session.addOutputWithNoConnections(output)

        let connection = AVCaptureConnection(inputPorts: [depthPort], output: output)
        guard session.canAddConnection(connection) else {
            os_log("Cannot add LiDAR depth connection.", type: .error)
            session.removeOutput(output)
            return
        }
        session.addConnection(connection)

        lidarDevice = device
        lidarDepthPort = depthPort
        lidarDepthOutput = output
        DispatchQueue.main.async {
            self.installDepthPreviewViewIfNeeded()
            self.layoutPreviewLayers()
            self.refreshOverlayStatus()
        }
    }

    private func configureLiDARDeviceForDepth(_ device: AVCaptureDevice) throws {
        let formatPair = preferredDepthFormatPair(for: device)
        guard let videoFormat = formatPair.videoFormat,
              let depthFormat = formatPair.depthFormat else {
            throw NSError(
                domain: "SensorRecorder",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "No supported LiDAR depth format found."]
            )
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = videoFormat
        device.activeDepthDataFormat = depthFormat

        let fps = supportedFrameRate(for: videoFormat, requested: depthEnabledCameraFrameRateLimit)
        let duration = frameDuration(for: min(fps, depthEnabledCameraFrameRateLimit))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func preferredDepthFormatPair(for device: AVCaptureDevice) -> (videoFormat: AVCaptureDevice.Format?, depthFormat: AVCaptureDevice.Format?) {
        var candidates: [(videoFormat: AVCaptureDevice.Format, depthFormat: AVCaptureDevice.Format, score: Int)] = []
        for videoFormat in device.formats {
            for depthFormat in videoFormat.supportedDepthDataFormats {
                let subtype = CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription)
                guard subtype == kCVPixelFormatType_DepthFloat32 || subtype == kCVPixelFormatType_DepthFloat16 else {
                    continue
                }
                let dimensions = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                let area = Int(dimensions.width) * Int(dimensions.height)
                let floatScore = subtype == kCVPixelFormatType_DepthFloat32 ? 1_000_000_000 : 0
                candidates.append((videoFormat, depthFormat, floatScore + area))
            }
        }
        return candidates.max(by: { $0.score < $1.score }).map { ($0.videoFormat, $0.depthFormat) } ?? (nil, nil)
    }

    private func configureSessionPresetForActiveFormats() {
        guard !(session is AVCaptureMultiCamSession) else { return }
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }
    }

    private func observeSessionRuntimeErrorsIfNeeded() {
        guard !observesSessionRuntimeErrors else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        NotificationCenter.default.addObserver(self, selector: #selector(captureSessionWasInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        observesSessionRuntimeErrors = true
    }

    private func configurePreviewCamera(
        deviceType: AVCaptureDevice.DeviceType,
        position: AVCaptureDevice.Position,
        cameraName: String,
        previewIndex: Int,
        settings: CameraCaptureSettings,
        requiresMultiCamFormat: Bool
    ) -> Bool {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: position) else {
            os_log("Camera unavailable: %@", type: .error, deviceType.rawValue)
            return false
        }

        do {
            var addedInput: AVCaptureDeviceInput?
            var addedOutput: AVCaptureVideoDataOutput?
            func cleanupPartialCameraConfiguration() {
                if let output = addedOutput {
                    session.removeOutput(output)
                }
                if let input = addedInput {
                    session.removeInput(input)
                }
            }

            try configureDeviceForPreview(device, settings: settings, requiresMultiCamFormat: requiresMultiCamFormat)
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInputWithNoConnections(input)
            addedInput = input
            applyInputFrameRateOverride(device, duration: device.activeVideoMinFrameDuration)

            guard let videoPort = input.ports.first(where: { $0.mediaType == .video }) else {
                cleanupPartialCameraConfiguration()
                return false
            }

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(videoOutput) else {
                cleanupPartialCameraConfiguration()
                return false
            }
            session.addOutputWithNoConnections(videoOutput)
            addedOutput = videoOutput

            let videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: videoOutput)
            guard session.canAddConnection(videoConnection) else {
                cleanupPartialCameraConfiguration()
                return false
            }
            session.addConnection(videoConnection)
            guard MultiCameraCaptureGraph.configureEncoderPixelFormat(videoOutput) else {
                cleanupPartialCameraConfiguration()
                return false
            }
            configureVideoConnection(videoConnection)
            if videoConnection.isCameraIntrinsicMatrixDeliverySupported {
                videoConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            if cameraName == "wide",
               device.deviceType == .builtInLiDARDepthCamera,
               recorderSettings.lidarDepthEnabled {
                configureDepthOutputIfNeeded(input: input, device: device)
            }

            DispatchQueue.main.async {
                let displayLayer = self.makeDisplayLayer(for: cameraName)
                self.sceneView.layer.insertSublayer(displayLayer, at: 0)
                if cameraName == "wide" {
                    self.wideDisplayLayer = displayLayer
                } else if cameraName == "ultrawide" {
                    self.ultraWideDisplayLayer = displayLayer
                } else if cameraName == "telephoto" {
                    self.telephotoDisplayLayer = displayLayer
                } else {
                    self.frontDisplayLayer = displayLayer
                }
                self.layoutPreviewLayers()
                self.view.bringSubviewToFront(self.startStopButton.superview ?? self.startStopButton)
            }

            if cameraName == "wide" {
                wideVideoPort = videoPort
                wideDevice = device
                if device.deviceType == .builtInLiDARDepthCamera {
                    lidarDevice = device
                }
                widePreviewOutput = videoOutput
            } else if cameraName == "ultrawide" {
                ultraWideVideoPort = videoPort
                ultraWideDevice = device
                ultraWidePreviewOutput = videoOutput
            } else if cameraName == "telephoto" {
                telephotoVideoPort = videoPort
                telephotoDevice = device
                telephotoPreviewOutput = videoOutput
            } else {
                frontVideoPort = videoPort
                frontDevice = device
                frontPreviewOutput = videoOutput
            }
            let activeDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            os_log(
                "Configured %@ camera requested %@ active %dx%d preset %@",
                cameraName,
                settings.resolution,
                activeDimensions.width,
                activeDimensions.height,
                session.sessionPreset.rawValue
            )
            return true
        } catch {
            os_log("Failed to configure camera %@: %@", type: .error, deviceType.rawValue, error.localizedDescription)
            return false
        }
    }

    private func configureAudioCapture() {
        guard audioOutput == nil else { return }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            os_log("Audio input unavailable.", type: .error)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                os_log("Cannot add audio input.", type: .error)
                return
            }
            session.addInputWithNoConnections(input)

            guard let audioPort = input.ports.first(where: { $0.mediaType == .audio }) else {
                os_log("Audio input has no audio port.", type: .error)
                return
            }

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(output) else {
                os_log("Cannot add audio output.", type: .error)
                return
            }
            session.addOutputWithNoConnections(output)

            let connection = AVCaptureConnection(inputPorts: [audioPort], output: output)
            guard session.canAddConnection(connection) else {
                os_log("Cannot add audio connection.", type: .error)
                return
            }
            session.addConnection(connection)
            audioOutput = output
        } catch {
            os_log("Failed to configure audio input: %@", type: .error, error.localizedDescription)
        }
    }

    private func configureAudioSessionForCapture() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setActive(true)
            if audioSession.maximumInputNumberOfChannels >= 2 {
                try audioSession.setPreferredInputNumberOfChannels(2)
            }
        } catch {
            os_log("Failed to configure audio session: %@", type: .error, error.localizedDescription)
        }
    }

    private func makeDisplayLayer(for cameraName: String) -> AVSampleBufferDisplayLayer {
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        return displayLayer
    }

    private func installDepthPreviewViewIfNeeded() {
        guard depthPreviewView == nil else { return }
        let imageView = UIImageView(frame: .zero)
        imageView.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        sceneView.insertSubview(imageView, at: 0)
        depthPreviewView = imageView
    }



    private func configureDeviceForPreview(
        _ device: AVCaptureDevice,
        settings: CameraCaptureSettings,
        requiresMultiCamFormat: Bool
    ) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        guard let format = preferredFormats(for: device, settings: settings, requiresMultiCamFormat: requiresMultiCamFormat).first else {
            throw NSError(domain: "SensorRecorder", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible recording format is available."])
        }
        device.activeFormat = format

        let fps = activeFrameRate(for: device, settings: settings)
        let duration = supportedFrameDuration(for: device.activeFormat, requested: fps)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        applyInputFrameRateOverride(device, duration: duration)
        if device.deviceType != .builtInLiDARDepthCamera {
            // A common policy does not imply identical sensor-specific gains/ISO.
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            } else if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                device.whiteBalanceMode = .autoWhiteBalance
            }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
            device.automaticallyAdjustsVideoHDREnabled = false
            if device.activeFormat.isVideoHDRSupported { device.isVideoHDREnabled = false }
        }
        applyAutoExposurePolicy(to: device, settings: settings)
        configureDepthFormatIfAvailable(for: device)

        if settings.autoFocus {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        } else if device.isFocusModeSupported(.locked) {
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(
                    lensPosition: lensPosition(for: settings, device: device),
                    completionHandler: nil
                )
            } else {
                device.focusMode = .locked
            }
        }
    }

    private func configureDepthFormatIfAvailable(for device: AVCaptureDevice) {
        guard device.deviceType == .builtInLiDARDepthCamera,
              let depthFormat = preferredDepthFormat(for: device.activeFormat) else {
            return
        }
        device.activeDepthDataFormat = depthFormat
    }

    private func preferredDepthFormat(for videoFormat: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        videoFormat.supportedDepthDataFormats
            .filter {
                let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return subtype == kCVPixelFormatType_DepthFloat32 || subtype == kCVPixelFormatType_DepthFloat16
            }
            .max { lhs, rhs in
                let lhsSubtype = CMFormatDescriptionGetMediaSubType(lhs.formatDescription)
                let rhsSubtype = CMFormatDescriptionGetMediaSubType(rhs.formatDescription)
                let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let lhsScore = (lhsSubtype == kCVPixelFormatType_DepthFloat32 ? 1_000_000_000 : 0) + Int(lhsDimensions.width) * Int(lhsDimensions.height)
                let rhsScore = (rhsSubtype == kCVPixelFormatType_DepthFloat32 ? 1_000_000_000 : 0) + Int(rhsDimensions.width) * Int(rhsDimensions.height)
                return lhsScore < rhsScore
            }
    }

    private func clampedLensPosition(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private func clampedLensPosition(_ value: Double?, fallback: Double) -> Double {
        clampedLensPosition(value ?? fallback)
    }

    private func lensPosition(for settings: CameraCaptureSettings, device: AVCaptureDevice) -> Float {
        let defaultLensPosition = device.deviceType == .builtInUltraWideCamera
            ? defaultUltraWideFixedFocusLensPosition
            : defaultWideFixedFocusLensPosition
        return Float(clampedLensPosition(settings.fixedFocusLensPosition, fallback: defaultLensPosition))
    }

    private func applyAutoExposurePolicy(to device: AVCaptureDevice, settings: CameraCaptureSettings) {
        guard isAutoExposureEnabled(for: settings) else {
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            return
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        } else if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
        }

        let requested = CMTimeMakeWithSeconds(
            maxExposureDurationSeconds(for: settings),
            preferredTimescale: 1_000_000_000
        )
        device.activeMaxExposureDuration = clampedExposureDuration(requested, for: device.activeFormat)
    }

    private func clampedExposureDuration(_ duration: CMTime, for format: AVCaptureDevice.Format) -> CMTime {
        if CMTimeCompare(duration, format.minExposureDuration) < 0 {
            return format.minExposureDuration
        }
        if CMTimeCompare(duration, format.maxExposureDuration) > 0 {
            return format.maxExposureDuration
        }
        return duration
    }

    private func preferredFormats(
        for device: AVCaptureDevice,
        settings: CameraCaptureSettings,
        requiresMultiCamFormat: Bool
    ) -> [AVCaptureDevice.Format] {
        let target = resolutionSize(from: settings.resolution) ?? CGSize(width: 1920, height: 1440)
        let targetWidth = Int(target.width)
        let targetHeight = Int(target.height)
        let targetArea = targetWidth * targetHeight
        return device.formats.filter { format in
            guard !requiresMultiCamFormat || format.isMultiCamSupported else { return false }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if recorderSettings.captureMode == .standard {
                guard Int(dimensions.width) == targetWidth,
                      Int(dimensions.height) == targetHeight,
                      supportsFPS(preferredCaptureFrameRateRequest(for: settings), format: format) else { return false }
            }
            return CameraStreamRecorder.isRecordableMP4Resolution(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
        }.sorted { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsArea = Int(lhsDims.width) * Int(lhsDims.height)
            let rhsArea = Int(rhsDims.width) * Int(rhsDims.height)

            let lhsExact = Int(lhsDims.width) == targetWidth && Int(lhsDims.height) == targetHeight
            let rhsExact = Int(rhsDims.width) == targetWidth && Int(rhsDims.height) == targetHeight
            if lhsExact != rhsExact {
                return lhsExact
            }

            let targetFPS = preferredCaptureFrameRateRequest(for: settings)
            let lhsFPSDistance = frameRateDistance(for: lhs, requested: targetFPS)
            let rhsFPSDistance = frameRateDistance(for: rhs, requested: targetFPS)
            if lhsFPSDistance != rhsFPSDistance {
                return lhsFPSDistance < rhsFPSDistance
            }

            let lhsUnderTarget = lhsArea <= targetArea
            let rhsUnderTarget = rhsArea <= targetArea
            if lhsUnderTarget != rhsUnderTarget {
                return lhsUnderTarget
            }

            if lhsUnderTarget && rhsUnderTarget && lhsArea != rhsArea {
                return lhsArea > rhsArea
            }

            let lhsDistance = abs(lhsArea - targetArea)
            let rhsDistance = abs(rhsArea - targetArea)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhsDims.width > rhsDims.width
        }
    }

    private func resolutionSize(from value: String) -> CGSize? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func clampedFrameRate(from value: String) -> Double {
        guard let fps = Double(value), fps.isFinite, fps > 0 else {
            return 30
        }
        return fps
    }

    private func targetRecordingFrameRate(for camera: RecordingCamera) -> Double {
        let requested: Double
        switch camera {
        case .wide:
            requested = clampedFrameRate(from: recorderSettings.wide.frameRate)
        case .ultraWide:
            requested = clampedFrameRate(from: recorderSettings.ultraWide.frameRate)
        case .telephoto:
            requested = clampedFrameRate(from: recorderSettings.telephoto.frameRate)
        case .front:
            requested = clampedFrameRate(from: recorderSettings.front.frameRate)
        }
        return limitedCameraFrameRate(requested)
    }

    private func targetRecordingFrameRate(for settings: CameraCaptureSettings) -> Double {
        limitedCameraFrameRate(clampedFrameRate(from: settings.frameRate))
    }

    private func limitedCameraFrameRate(_ requested: Double) -> Double {
        recorderSettings.captureMode == .arkit && recorderSettings.lidarDepthEnabled
            ? min(requested, depthEnabledCameraFrameRateLimit) : requested
    }

    private func isAutoExposureEnabled(for settings: CameraCaptureSettings) -> Bool {
        settings.autoExposure ?? true
    }

    private func maxExposureDurationSeconds(for settings: CameraCaptureSettings) -> TimeInterval {
        let defaultMilliseconds = Double(defaultCameraAutoExposureMaxDurationMS) ?? 10
        let milliseconds = Double(settings.maxExposureDurationMS ?? defaultCameraAutoExposureMaxDurationMS) ?? defaultMilliseconds
        return min(max(milliseconds, 0.1), 1000) / 1000.0
    }

    private func maxExposureDurationLabel(for settings: CameraCaptureSettings) -> String {
        settings.maxExposureDurationMS ?? defaultCameraAutoExposureMaxDurationMS
    }

    private func preferredCaptureFrameRateRequest(for settings: CameraCaptureSettings) -> Double {
        targetRecordingFrameRate(for: settings)
    }

    private func supportedFrameRate(for format: AVCaptureDevice.Format, requested: Double) -> Double {
        guard let range = format.videoSupportedFrameRateRanges.min(by: { lhs, rhs in
            let lhsClamped = min(max(requested, lhs.minFrameRate), lhs.maxFrameRate)
            let rhsClamped = min(max(requested, rhs.minFrameRate), rhs.maxFrameRate)
            return abs(lhsClamped - requested) < abs(rhsClamped - requested)
        }) else {
            return requested
        }
        return min(max(requested, range.minFrameRate), range.maxFrameRate)
    }

    private func frameRateDistance(for format: AVCaptureDevice.Format, requested: Double) -> Double {
        abs(supportedFrameRate(for: format, requested: requested) - requested)
    }

    private func activeFrameRate(for device: AVCaptureDevice?, settings: CameraCaptureSettings) -> Double {
        guard let device else { return 0 }
        let controller = multiCameraGraph?.controller(forSourceDevice: device) ?? device
        return supportedFrameRate(for: controller.activeFormat, requested: preferredCaptureFrameRateRequest(for: settings))
    }

    private func frameDuration(for fps: Double) -> CMTime {
        let scale: Int32 = recorderSettings.captureMode == .standard ? 60_000 : 600
        let value = max(Int64(round(Double(scale) / max(fps, 0.1))), 1)
        return CMTime(value: value, timescale: scale)
    }

    private func supportedFrameDuration(for format: AVCaptureDevice.Format, requested: Double) -> CMTime {
        let fps = supportedFrameRate(for: format, requested: requested)
        let ranges = format.videoSupportedFrameRateRanges
        guard let range = ranges.first(where: { fps >= $0.minFrameRate && fps <= $0.maxFrameRate }) else {
            return frameDuration(for: fps)
        }
        let duration = CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000)
        if CMTimeCompare(duration, range.minFrameDuration) < 0 { return range.minFrameDuration }
        if CMTimeCompare(duration, range.maxFrameDuration) > 0 { return range.maxFrameDuration }
        return duration
    }

    private func applyInputFrameRateOverride(_ device: AVCaptureDevice, duration: CMTime) {
        guard session is AVCaptureMultiCamSession,
              let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device === device }) else { return }
        input.videoMinFrameDurationOverride = duration
    }

    private func multicamBudgetIsExceeded() -> Bool {
        guard let multiCamSession = session as? AVCaptureMultiCamSession else { return false }
        return multiCamSession.hardwareCost > 1.0 || multiCamSession.systemPressureCost > 1.0
    }

    private func settingsDevice(_ key: String, settings: RecorderSettings) -> AVCaptureDevice? {
        switch key {
        case "wide":
            return AVCaptureDevice.default(settings.lidarDepthEnabled ? .builtInLiDARDepthCamera : .builtInWideAngleCamera,
                                           for: .video, position: .back)
        case "ultra": return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case "telephoto": return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case "front": return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        default: return nil
        }
    }

    private func formatResolution(_ format: AVCaptureDevice.Format) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return "\(size.width)x\(size.height)"
    }

    private func supportsFPS(_ fps: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { fps >= $0.minFrameRate - 0.001 && fps <= $0.maxFrameRate + 0.001 }
    }

    private func depthFormats(_ video: AVCaptureDevice.Format) -> [AVCaptureDevice.Format] {
        video.supportedDepthDataFormats.filter {
            let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return subtype == kCVPixelFormatType_DepthFloat32 || subtype == kCVPixelFormatType_DepthFloat16
        }
    }

    private func capabilityFormats(_ key: String, settings: RecorderSettings) -> [AVCaptureDevice.Format] {
        if enabledCameraCount(in: settings) > 1 {
            guard !settings.lidarDepthEnabled, let camera = PhysicalCamera.allCases.first(where: { $0.settingsKey == key }),
                  let device = MultiCameraCaptureGraph.controllerDevice(for: camera, cameras: enabledPhysicalCameras(settings)) else { return [] }
            return device.formats.filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return format.isMultiCamSupported && CameraStreamRecorder.isRecordableMP4Resolution(width: Int(size.width), height: Int(size.height))
            }
        }
        guard let device = settingsDevice(key, settings: settings) else { return [] }
        let multicam = settings.lidarDepthEnabled || enabledCameraCount(in: settings) > 1
        return device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (!multicam || format.isMultiCamSupported) &&
                CameraStreamRecorder.isRecordableMP4Resolution(width: Int(size.width), height: Int(size.height)) &&
                (key != "wide" || !settings.lidarDepthEnabled || !depthFormats(format).isEmpty)
        }
    }

    private func resolutionChoices(_ formats: [AVCaptureDevice.Format]) -> [String] {
        Array(Set(formats.map(formatResolution))).sorted {
            let a = resolutionSize(from: $0) ?? .zero
            let b = resolutionSize(from: $1) ?? .zero
            return a.width * a.height > b.width * b.height
        }
    }

    private func frameRateChoices(_ formats: [AVCaptureDevice.Format], ceiling: Double = .greatestFiniteMagnitude) -> [String] {
        let ranges = formats.flatMap { $0.videoSupportedFrameRateRanges }.map { $0.minFrameRate...$0.maxFrameRate }
        return CaptureRateOptions.choices(ranges: ranges, ceiling: ceiling)
    }

    private func settingsDraft() -> RecorderSettings {
        var draft = recorderSettings
        draft.captureMode = settingsMenuButtons["captureMode"]?.accessibilityValue == "ARKit" ? .arkit : .standard
        draft.lidarDepthEnabled = settingsSwitches["lidarDepth"]?.isOn ?? draft.lidarDepthEnabled
        draft.audioEnabled = settingsSwitches["audio"]?.isOn ?? draft.audioEnabled
        func camera(_ key: String, _ stored: CameraCaptureSettings) -> CameraCaptureSettings {
            var value = stored
            value.enabled = settingsSwitches["\(key).enabled"]?.isOn ?? value.enabled
            value.autoFocus = settingsSwitches["shared.autoFocus"]?.isOn ?? settingsSwitches["\(key).autoFocus"]?.isOn ?? value.autoFocus
            value.fixedFocusLensPosition = settingsSliders["\(key).fixedFocus"].map { Double($0.value) } ?? value.fixedFocusLensPosition
            if draft.captureMode == .standard && value.enabled {
                value.resolution = selectedSettingsValue(for: "shared.resolution", fallback: value.resolution)
                value.frameRate = selectedSettingsValue(for: "shared.frameRate", fallback: value.frameRate)
                value.autoExposure = settingsSwitches["shared.autoExposure"]?.isOn ?? isAutoExposureEnabled(for: value)
                value.maxExposureDurationMS = selectedSettingsValue(for: "shared.maxExposure", fallback: maxExposureDurationLabel(for: value))
            }
            return value
        }
        draft.wide = camera("wide", draft.wide)
        draft.ultraWide = camera("ultra", draft.ultraWide)
        draft.telephoto = camera("telephoto", draft.telephoto)
        draft.front = camera("front", draft.front)
        return draft
    }

    private func depthCapabilityPairs(settings: RecorderSettings) -> [(video: AVCaptureDevice.Format, depth: AVCaptureDevice.Format)] {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else { return [] }
        let multicam = settings.lidarDepthEnabled || enabledCameraCount(in: settings) > 1
        return device.formats.flatMap { video -> [(video: AVCaptureDevice.Format, depth: AVCaptureDevice.Format)] in
            guard !multicam || video.isMultiCamSupported else { return [] }
            if settings.wide.enabled {
                guard formatResolution(video) == settings.wide.resolution,
                      supportsFPS(clampedFrameRate(from: settings.wide.frameRate), format: video) else { return [] }
            }
            return depthFormats(video).filter { depth in
                !settings.wide.enabled || depth.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= clampedFrameRate(from: settings.wide.frameRate)
                }
            }.map { (video, $0) }
        }
    }

    // Called only on sessionQueue while the settings controller covers preview.
    // Probe the complete graph, including all other cameras, never a lens alone.
    private func jointConfigurationFits(_ settings: RecorderSettings) -> Bool {
        guard standardConfigurationIssue(settings) == nil else { return false }
        if enabledCameraCount(in: settings) > 1 {
            guard let request = multiCameraRequest(settings) else { return false }
            do {
                let graph = try MultiCameraCaptureGraph.make(request)
                defer { graph.close() }
                guard sdkEncoderPlanFits(settings) else { return false }
                validatedMultiCameraFormats[multiCameraProfileKey(request)] = graph.formats
                return true
            } catch { return false }
        }
        let graph = makeCaptureSession(for: settings)
        graph.beginConfiguration()
        if !(graph is AVCaptureMultiCamSession), graph.canSetSessionPreset(.inputPriority) {
            graph.sessionPreset = .inputPriority
        }
        var committed = false
        defer {
            if !committed { graph.commitConfiguration() }
            graph.beginConfiguration()
            graph.outputs.forEach { graph.removeOutput($0) }
            graph.inputs.forEach { graph.removeInput($0) }
            graph.commitConfiguration()
        }
        var depthConnected = false
        let cameras = [("wide", settings.wide), ("ultra", settings.ultraWide),
                       ("telephoto", settings.telephoto), ("front", settings.front)]
        for (key, camera) in cameras where camera.enabled {
            guard let device = settingsDevice(key, settings: settings),
                  let format = capabilityFormats(key, settings: settings).first(where: {
                      formatResolution($0) == camera.resolution && supportsFPS(clampedFrameRate(from: camera.frameRate), format: $0) &&
                      (key != "wide" || !settings.lidarDepthEnabled || compatibleDepthFormat(video: $0, settings: settings) != nil)
                  }) else { return false }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = supportedFrameDuration(for: format, requested: clampedFrameRate(from: camera.frameRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                if key == "wide", settings.lidarDepthEnabled,
                   let depth = compatibleDepthFormat(video: format, settings: settings) {
                    device.activeDepthDataFormat = depth
                }
                device.unlockForConfiguration()
                let input = try AVCaptureDeviceInput(device: device)
                guard graph.canAddInput(input) else { return false }
                graph.addInputWithNoConnections(input)
                if graph is AVCaptureMultiCamSession { input.videoMinFrameDurationOverride = duration }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = false
                output.automaticallyConfiguresOutputBufferDimensions = false
                output.deliversPreviewSizedOutputBuffers = false
                guard graph.canAddOutput(output), let port = input.ports.first(where: { $0.mediaType == .video }) else { return false }
                graph.addOutputWithNoConnections(output)
                let connection = AVCaptureConnection(inputPorts: [port], output: output)
                guard graph.canAddConnection(connection) else { return false }
                graph.addConnection(connection)
                guard MultiCameraCaptureGraph.configureEncoderPixelFormat(output) else { return false }
                configureVideoConnection(connection)
                if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
                if key == "wide", settings.lidarDepthEnabled {
                    guard addProbeDepthOutput(input: input, graph: graph) else { return false }
                    depthConnected = true
                }
            } catch { return false }
        }
        if settings.lidarDepthEnabled && !depthConnected {
            guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
                  let pair = depthCapabilityPairs(settings: settings).filter({
                      compatibleDepthFormat(video: $0.video, settings: settings) === $0.depth &&
                      supportsFPS(depthEnabledCameraFrameRateLimit, format: $0.video)
                  }).max(by: { a, b in depthProbeScore(a.depth) < depthProbeScore(b.depth) }) else { return false }
            do {
                try device.lockForConfiguration()
                device.activeFormat = pair.video
                device.activeDepthDataFormat = pair.depth
                let duration = supportedFrameDuration(for: pair.video, requested: depthEnabledCameraFrameRateLimit)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                let input = try AVCaptureDeviceInput(device: device)
                guard graph.canAddInput(input) else { return false }
                graph.addInputWithNoConnections(input)
                if graph is AVCaptureMultiCamSession { input.videoMinFrameDurationOverride = duration }
                guard addProbeDepthOutput(input: input, graph: graph) else { return false }
            } catch { return false }
        }
        if settings.audioEnabled {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  let device = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device), graph.canAddInput(input) else { return false }
            graph.addInput(input)
            let output = AVCaptureAudioDataOutput()
            guard graph.canAddOutput(output) else { return false }
            graph.addOutput(output)
        }
        graph.commitConfiguration()
        committed = true
        if let multi = graph as? AVCaptureMultiCamSession {
            guard multi.hardwareCost.isFinite, multi.systemPressureCost.isFinite,
                  multi.hardwareCost <= 1, multi.systemPressureCost <= 1 else { return false }
        }
        for (key, camera) in cameras where camera.enabled {
            guard let device = settingsDevice(key, settings: settings), formatResolution(device.activeFormat) == camera.resolution else { return false }
            let min = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            let max = CMTimeGetSeconds(device.activeVideoMaxFrameDuration)
            let fps = clampedFrameRate(from: camera.frameRate)
            guard min > 0, max > 0, abs(1 / min - fps) < 0.01, abs(1 / max - fps) < 0.01 else { return false }
        }
        if settings.lidarDepthEnabled {
            guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
                  device.activeDepthDataFormat != nil else { return false }
        }
        return sdkEncoderPlanFits(settings)
    }

    private func sdkEncoderPlanFits(_ settings: RecorderSettings) -> Bool {
        let cameras = [settings.wide, settings.ultraWide, settings.telephoto, settings.front].filter(\.enabled)
        var encoders: [RealtimeVideoEncoder] = []
        do {
            for camera in cameras {
                guard let size = resolutionSize(from: camera.resolution) else { return false }
                let width = Int(size.width), height = Int(size.height)
                let codec = CameraStreamRecorder.preferredVideoCodec(width: width, height: height)
                encoders.append(try RealtimeVideoEncoder(width: width, height: height,
                    codec: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                    framesPerSecond: clampedFrameRate(from: camera.frameRate),
                    bitRate: CameraStreamRecorder.videoBitRate(width: width, height: height, codec: codec,
                                                              framesPerSecond: clampedFrameRate(from: camera.frameRate))))
            }
            // Keep every SDK session alive together to check joint availability,
            // rather than checking each encoder in isolation.
            return withExtendedLifetime(encoders) { true }
        } catch { return false }
    }

    private func compatibleDepthFormat(video: AVCaptureDevice.Format, settings _: RecorderSettings) -> AVCaptureDevice.Format? {
        preferredDepthFormat(for: video)
    }

    private func depthProbeScore(_ format: AVCaptureDevice.Format) -> Int {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_DepthFloat32 ? 1_000_000_000 : 0) + Int(size.width) * Int(size.height)
    }

    private func addProbeDepthOutput(input: AVCaptureDeviceInput, graph: AVCaptureSession) -> Bool {
        guard let port = input.ports.first(where: { $0.mediaType == .depthData }) else { return false }
        let output = AVCaptureDepthDataOutput()
        output.isFilteringEnabled = true
        output.alwaysDiscardsLateDepthData = true
        guard graph.canAddOutput(output) else { return false }
        graph.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard graph.canAddConnection(connection) else { return false }
        graph.addConnection(connection)
        return true
    }

    private func withRestoredCaptureDevices<T>(_ body: () -> T) -> T {
        let types: [AVCaptureDevice.DeviceType] = [.builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera, .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInLiDARDepthCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices.sorted { $0.isVirtualDevice && !$1.isVirtualDevice }
        let snapshots = devices.map { ($0, $0.activeFormat, $0.activeVideoMinFrameDuration, $0.activeVideoMaxFrameDuration,
                                       $0.activeDepthDataFormat, $0.activeDepthDataMinFrameDuration, $0.activeMaxExposureDuration,
                                       $0.focusMode, $0.lensPosition, $0.exposureMode, $0.whiteBalanceMode, $0.deviceWhiteBalanceGains) }
        let running = session.isRunning
        if running { session.stopRunning() }
        defer {
            for (device, format, min, max, depth, depthMin, exposureMax, focus, lens, exposure, whiteBalance, gains) in snapshots {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = format
                    device.activeVideoMinFrameDuration = min
                    device.activeVideoMaxFrameDuration = max
                    // RGB-only devices reject even a nil depth-format setter.
                    // Restore depth only when the original video format declares it.
                    if let depth, format.supportedDepthDataFormats.contains(depth) {
                        device.activeDepthDataFormat = depth
                        if CMTimeGetSeconds(depthMin).isFinite, CMTimeGetSeconds(depthMin) > 0 {
                            device.activeDepthDataMinFrameDuration = depthMin
                        }
                    }
                    device.activeMaxExposureDuration = clampedExposureDuration(exposureMax, for: format)
                    if device.isFocusModeSupported(focus) {
                        if focus == .locked && device.isLockingFocusWithCustomLensPositionSupported {
                            device.setFocusModeLocked(lensPosition: lens, completionHandler: nil)
                        } else { device.focusMode = focus }
                    }
                    if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
                    if device.isWhiteBalanceModeSupported(whiteBalance) {
                        if whiteBalance == .locked { device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil) }
                        else { device.whiteBalanceMode = whiteBalance }
                    }
                    device.unlockForConfiguration()
                } catch { os_log("Could not restore device after settings scan: %@", type: .error, error.localizedDescription) }
            }
            if running { session.startRunning() }
        }
        return body()
    }

    private func replacingCaptureValue(_ settings: RecorderSettings, key: String, value: String) -> RecorderSettings {
        var result = settings
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return result }
        func replace(_ camera: inout CameraCaptureSettings) {
            if parts[1] == "resolution" { camera.resolution = value }
            else { camera.frameRate = value }
        }
        switch parts[0] {
        case "wide": replace(&result.wide)
        case "ultra": replace(&result.ultraWide)
        case "telephoto": replace(&result.telephoto)
        case "front": replace(&result.front)
        case "shared":
            if result.wide.enabled { replace(&result.wide) }
            if result.ultraWide.enabled { replace(&result.ultraWide) }
            if result.telephoto.enabled { replace(&result.telephoto) }
            if result.front.enabled { replace(&result.front) }
        default: break
        }
        return result
    }

    private func installVerifiedMenu(key: String, candidates: [String], draft: RecorderSettings, generation: UUID) {
        guard let button = settingsMenuButtons[key] else { return }
        settingsMenuHasCandidates[key] = !candidates.isEmpty
        let selected = button.accessibilityValue ?? ""
        var plan = draft
        if key.hasPrefix("shared.") {
            for field in ["resolution", "frameRate"] {
                if let value = settingsMenuButtons["shared.\(field)"]?.accessibilityValue {
                    plan = replacingCaptureValue(plan, key: "shared.\(field)", value: value)
                }
            }
        }
        let basePlan = plan
        button.isEnabled = !candidates.isEmpty
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak button] completion in
            guard let self else { completion([]); return }
            self.sessionQueue.async {
                guard !self.isRecording else { DispatchQueue.main.async { completion([]) }; return }
                let valid: [(String, RecorderSettings)] = self.withRestoredCaptureDevices {
                    candidates.compactMap { value in
                        autoreleasepool {
                            let candidate = self.replacingCaptureValue(basePlan, key: key, value: value)
                            if key == "shared.resolution" {
                                let current = [basePlan.wide, basePlan.ultraWide, basePlan.telephoto, basePlan.front].first(where: \.enabled)?.frameRate ?? "30"
                                for rate in CaptureRateOptions.compatibleOrder(current: current, choices: self.commonRateChoices(candidate)) {
                                    let compatible = self.replacingCaptureValue(candidate, key: "shared.frameRate", value: rate)
                                    if self.jointConfigurationFits(compatible) { return (value, compatible) }
                                }
                                return nil
                            }
                            return self.jointConfigurationFits(candidate) ? (value, candidate) : nil
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard self.settingsCapabilityGeneration == generation, self.settingsOverlayView != nil else { completion([]); return }
                    let actions = valid.map { value, compatible in
                        UIAction(title: value, state: value == selected ? .on : .off) { [weak self, weak button] _ in
                            guard let self, self.settingsCapabilityGeneration == generation else { return }
                            button?.accessibilityValue = value
                            button?.configuration = self.settingsMenuConfiguration(title: value, compact: true)
                            if key == "shared.resolution",
                               let rate = [compatible.wide, compatible.ultraWide, compatible.telephoto, compatible.front].first(where: \.enabled)?.frameRate {
                                // Resolution and cadence form one settings edit.
                                // Only a jointly checked pair reaches the draft.
                                self.settingsMenuButtons["shared.frameRate"]?.accessibilityValue = rate
                                self.settingsMenuButtons["shared.frameRate"]?.configuration = self.settingsMenuConfiguration(title: rate, compact: true)
                            }
                            self.settingsFormatSelectionChanged(key)
                        }
                    }
                    if actions.isEmpty {
                        completion([UIAction(title: "No compatible options for this combination", attributes: .disabled, handler: { _ in })])
                    } else { completion(actions) }
                }
            }
        }])
    }

    private func standardConfigurationIssue(_ settings: RecorderSettings) -> String? {
        let enabled = [settings.wide, settings.ultraWide, settings.telephoto, settings.front].filter(\.enabled)
        if enabled.contains(where: { !CaptureRateOptions.isWithinProductLimit(Double($0.frameRate) ?? .nan) }) {
            return "This version supports up to 60 fps. Select an SDK-supported frame rate of 60 fps or lower in Settings."
        }
        if let first = enabled.first, enabled.contains(where: {
            $0.resolution != first.resolution || $0.frameRate != first.frameRate ||
            isAutoExposureEnabled(for: $0) != isAutoExposureEnabled(for: first) ||
            maxExposureDurationLabel(for: $0) != maxExposureDurationLabel(for: first)
        }) { return "Choose one shared resolution, frame rate and exposure policy for the camera combination." }
        guard isCameraSetSupportedByMultiCam(settings: settings) else {
            return "This device does not support the selected camera combination."
        }
        let configuredCameras = [("wide", settings.wide), ("ultra", settings.ultraWide),
                       ("telephoto", settings.telephoto), ("front", settings.front)]
        for (key, camera) in configuredCameras where camera.enabled {
            let matches = capabilityFormats(key, settings: settings).filter {
                formatResolution($0) == camera.resolution && supportsFPS(clampedFrameRate(from: camera.frameRate), format: $0)
            }
            if matches.isEmpty { return "\(key): \(camera.resolution) at \(camera.frameRate) Hz is not supported by this camera configuration." }
        }
        if settings.lidarDepthEnabled {
            if enabled.contains(where: { clampedFrameRate(from: $0.frameRate) > depthEnabledCameraFrameRateLimit }) {
                return "The existing Depth capture path limits RGB to 10 Hz. Select a supported rate or disable Depth."
            }
            if depthCapabilityPairs(settings: settings).isEmpty { return "Depth is unavailable with this camera configuration." }
        }
        return nil
    }

    private func activeStandardConfigurationIssue() -> String? {
        if enabledCameraCount(in: recorderSettings) > 1 {
            guard let graph = multiCameraGraph else { return "The multi-camera capture graph is unavailable." }
            return graph.configurationIssue()
        }
        let cameras = [("Wide", recorderSettings.wide, wideDevice),
                       ("Ultra-wide", recorderSettings.ultraWide, ultraWideDevice),
                       ("Telephoto", recorderSettings.telephoto, telephotoDevice),
                       ("Front", recorderSettings.front, frontDevice)]
        for (name, settings, device) in cameras where settings.enabled {
            guard let device else { return "\(name) is unavailable. Please update its settings." }
            if let expected = configuredCameraFormats[device.uniqueID], device.activeFormat !== expected {
                return "\(name)'s validated format changed. Revalidate the settings before recording."
            }
            let seconds = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            let fps = seconds > 0 ? 1 / seconds : 0
            let maxSeconds = CMTimeGetSeconds(device.activeVideoMaxFrameDuration)
            let minimumFPS = maxSeconds > 0 ? 1 / maxSeconds : 0
            let requested = clampedFrameRate(from: settings.frameRate)
            if !fps.isFinite || !minimumFPS.isFinite ||
                formatResolution(device.activeFormat) != settings.resolution ||
                abs(fps - requested) > 0.01 || abs(minimumFPS - requested) > 0.01 {
                return "\(name) could not apply \(settings.resolution) at \(settings.frameRate) Hz. Please choose a compatible configuration."
            }
        }
        if recorderSettings.lidarDepthEnabled && lidarDevice?.activeDepthDataFormat == nil {
            return "Depth is unavailable with this camera configuration."
        }
        return multicamBudgetIsExceeded() ? "The selected formats exceed this device's multi-camera capture budget." : nil
    }

    private func arkitResolutionOptions(for preferredResolution: String) -> [String] {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let options = formats.compactMap { format -> (label: String, area: Int)? in
            let width = Int(format.imageResolution.width)
            let height = Int(format.imageResolution.height)
            guard width > 0, height > 0 else { return nil }
            guard CameraStreamRecorder.isRecordableMP4Resolution(width: width, height: height) else { return nil }
            return ("\(width)x\(height)", width * height)
        }

        let unique = Dictionary(options.map { ($0.label, $0.area) }, uniquingKeysWith: max)
        let sorted = unique.sorted { $0.value > $1.value }
        var labels = sorted.map(\.key)
        let preferred = preferredResolution
        if !labels.contains(preferred) && preferred.contains("x") {
            labels.insert(preferred, at: 0)
        }
        return labels.isEmpty ? ["1920x1440", "1280x720"] : labels
    }

    private func configureVideoConnection(_ connection: AVCaptureConnection) {
        connection.preferredVideoStabilizationMode = .off
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }

    private func layoutPreviewLayers() {
        let bounds = sceneView.bounds
        diagnosticLayer?.frame = bounds.insetBy(dx: 24, dy: 24)
        singlePreviewView?.frame = bounds
        singlePreviewLayer?.frame = bounds

        if arkitDisplayLayer != nil {
            layoutSampleBufferDisplayLayer(arkitDisplayLayer, in: bounds)
            return
        }

        if previewDebugMode != .dual {
            layoutSampleBufferDisplayLayer(wideDisplayLayer, in: bounds)
            layoutSampleBufferDisplayLayer(ultraWideDisplayLayer, in: bounds)
            layoutSampleBufferDisplayLayer(telephotoDisplayLayer, in: bounds)
            layoutSampleBufferDisplayLayer(frontDisplayLayer, in: bounds)
            wideCameraPreviewView?.frame = bounds
            ultraWideCameraPreviewView?.frame = bounds
            telephotoCameraPreviewView?.frame = bounds
            frontCameraPreviewView?.frame = bounds
            depthPreviewView?.frame = bounds
            widePreviewLayer?.frame = wideCameraPreviewView?.bounds ?? bounds
            ultraWidePreviewLayer?.frame = ultraWideCameraPreviewView?.bounds ?? bounds
            telephotoPreviewLayer?.frame = telephotoCameraPreviewView?.bounds ?? bounds
            frontPreviewLayer?.frame = frontCameraPreviewView?.bounds ?? bounds
            return
        }

        let activeKeys = activePreviewTileKeys()
        hudContentRect = previewContentRect(in: bounds, tileCount: activeKeys.count)
        let frames = previewTileFrames(in: hudContentRect, activeKeys: activeKeys)
        let ultraFrame = frames["ultra"] ?? .zero
        let wideFrame = frames["wide"] ?? .zero
        let telephotoFrame = frames["telephoto"] ?? .zero
        let frontFrame = frames["front"] ?? .zero
        let depthFrame = frames["depth"] ?? .zero
        layoutSampleBufferDisplayLayer(wideDisplayLayer, in: wideFrame)
        layoutSampleBufferDisplayLayer(ultraWideDisplayLayer, in: ultraFrame)
        layoutSampleBufferDisplayLayer(telephotoDisplayLayer, in: telephotoFrame)
        layoutSampleBufferDisplayLayer(frontDisplayLayer, in: frontFrame)
        wideCameraPreviewView?.frame = wideFrame
        ultraWideCameraPreviewView?.frame = ultraFrame
        telephotoCameraPreviewView?.frame = telephotoFrame
        frontCameraPreviewView?.frame = frontFrame
        depthPreviewView?.frame = depthFrame
        widePreviewLayer?.frame = wideCameraPreviewView?.bounds ?? .zero
        ultraWidePreviewLayer?.frame = ultraWideCameraPreviewView?.bounds ?? .zero
        telephotoPreviewLayer?.frame = telephotoCameraPreviewView?.bounds ?? .zero
        frontPreviewLayer?.frame = frontCameraPreviewView?.bounds ?? .zero
        layoutHUDOverlays(frames: frames)
    }

    private func activePreviewTileKeys() -> [String] {
        [
            ultraWidePreviewOutput != nil ? "ultra" : nil,
            widePreviewOutput != nil ? "wide" : nil,
            telephotoPreviewOutput != nil ? "telephoto" : nil,
            frontPreviewOutput != nil ? "front" : nil,
            lidarDepthOutput != nil ? "depth" : nil
        ].compactMap { $0 }
    }

    private func previewContentRect(in bounds: CGRect, tileCount: Int) -> CGRect {
        let targetAspect: CGFloat
        switch max(tileCount, 1) {
        case 1:
            targetAspect = 4.0 / 3.0
        case 2:
            targetAspect = 8.0 / 3.0
        case 3:
            targetAspect = 4.0
        case 4:
            targetAspect = 4.0 / 3.0
        default:
            targetAspect = 2.0
        }
        var width = bounds.width
        var height = width / targetAspect
        if height > bounds.height {
            height = bounds.height
            width = height * targetAspect
        }
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    private func previewTileFrames(in contentRect: CGRect, activeKeys: [String]) -> [String: CGRect] {
        guard !activeKeys.isEmpty else { return [:] }

        let rows: [[String]]
        switch activeKeys.count {
        case 1, 2, 3:
            rows = [activeKeys]
        case 4:
            rows = [Array(activeKeys.prefix(2)), Array(activeKeys.dropFirst(2))]
        default:
            rows = [Array(activeKeys.prefix(3)), Array(activeKeys.dropFirst(3).prefix(2))]
        }

        let maxColumns = rows.map(\.count).max() ?? 1
        let rowHeight = contentRect.height / CGFloat(rows.count)
        let tileWidth = contentRect.width / CGFloat(maxColumns)
        return rows.enumerated().reduce(into: [:]) { result, rowEntry in
            let rowIndex = rowEntry.offset
            let rowKeys = rowEntry.element
            let rowWidth = tileWidth * CGFloat(rowKeys.count)
            let rowX = contentRect.minX + (contentRect.width - rowWidth) / 2
            for (columnIndex, key) in rowKeys.enumerated() {
                result[key] = CGRect(
                    x: rowX + CGFloat(columnIndex) * tileWidth,
                    y: contentRect.minY + CGFloat(rowIndex) * rowHeight,
                    width: tileWidth,
                    height: rowHeight
                ).integral
            }
        }
    }

    private func layoutHUDOverlays(frames: [String: CGRect]) {
        guard !cameraStatusRows.isEmpty || !captureStatusRows.isEmpty else { return }
        for key in ["ultra", "wide", "telephoto", "front", "depth"] {
            let frame = frames[key] ?? .zero
            cameraStatusBadges[key]?.isHidden = frame.isEmpty
            if !frame.isEmpty {
                let width: CGFloat = key == "ultra" ? 348 : 300
                cameraStatusBadges[key]?.frame = CGRect(x: frame.midX - width / 2, y: frame.minY + 2, width: width, height: 30)
            }
        }
        let summaryWidth = min(max(hudContentRect.width * 0.58, 560), max(hudContentRect.width - 220, 320))
        let summaryY = max(4, hudContentRect.minY - 42)
        captureStatusBadges["summary"]?.frame = CGRect(
            x: hudContentRect.midX - summaryWidth / 2,
            y: summaryY,
            width: summaryWidth,
            height: 36
        )
        cameraStatusBadges["wide"].map { sceneView.bringSubviewToFront($0) }
        cameraStatusBadges["ultra"].map { sceneView.bringSubviewToFront($0) }
        cameraStatusBadges["telephoto"].map { sceneView.bringSubviewToFront($0) }
        cameraStatusBadges["front"].map { sceneView.bringSubviewToFront($0) }
        cameraStatusBadges["depth"].map { sceneView.bringSubviewToFront($0) }
        captureStatusBadges["summary"].map { view.bringSubviewToFront($0) }
        if let modeBadge {
            view.bringSubviewToFront(modeBadge)
        }
        if let sensorMonitorBar {
            view.bringSubviewToFront(sensorMonitorBar)
        }
        if let freeCountdownLabel {
            view.bringSubviewToFront(freeCountdownLabel)
        }
        if let rightControlRail {
            view.bringSubviewToFront(rightControlRail)
        }
        if let settingsOverlayView {
            view.bringSubviewToFront(settingsOverlayView)
        }
    }

    private func layoutSampleBufferDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer?, in frame: CGRect) {
        guard let displayLayer = displayLayer else { return }
        displayLayer.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        displayLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        displayLayer.setAffineTransform(.identity)
    }

    private func setStatus(_ status: String) {
        DispatchQueue.main.async {
            let frame = self.sceneView.bounds
            let running: String
            if self.previewDebugMode == .wideOnly {
                running = self.singlePreviewSession?.isRunning == true ? "running" : "stopped"
            } else {
                running = self.session.isRunning ? "running" : "stopped"
            }
            if !self.isRecording {
                self.timeLabel.text = status
            }
            self.frameCounterLabel.text = "\(self.previewDebugMode.rawValue), \(running), W \(self.wideFrameCount), U \(self.ultraWideFrameCount), T \(self.telephotoFrameCount), F \(self.frontFrameCount), S \(self.singleFrameCount), \(Int(frame.width))x\(Int(frame.height))"
            self.refreshOverlayStatus()
        }
    }

    private func startRecording() {
        guard !isRecording, recordingTransition == .none else { return }
        if isARKitMode && !CaptureRateOptions.isWithinProductLimit(Double(recorderSettings.arkitCamera.frameRate) ?? .nan) {
            showError(msg: "This version supports up to 60 fps. Select a supported frame rate in Settings.")
            return
        }
        recordingTransition = .preparing
        let startClock = CACurrentMediaTime()
        logRecordingStartStep("tap", startClock: startClock)
        startStopButton.isEnabled = false
        timeLabel.text = "Preparing"

        ensurePermissions(requiredPermissions(for: recorderSettings)) { granted in
            DispatchQueue.main.async {
                self.logRecordingStartStep("permissions", startClock: startClock)
                guard granted else {
                    self.recordingTransition = .none
                    self.startStopButton.isEnabled = true
                    self.timeLabel.text = "Permission needed"
                    return
                }
                guard UIApplication.shared.applicationState != .background else {
                    self.recordingTransition = .none
                    self.startStopButton.isEnabled = true
                    self.endRecordingBackgroundTask()
                    self.deferredRecordingError = "Recording was interrupted before it could start because the app entered the background."
                    return
                }
                self.startRecordingAfterPermissionChecks(startClock: startClock)
            }
        }
    }

    private func startRecordingAfterPermissionChecks(startClock: CFTimeInterval) {
        if isARKitMode {
            guard isConfigured, arSession != nil else {
                startStopButton.isEnabled = true
                showError(msg: "ARKit session is not ready yet.")
                return
            }

            guard createFiles() else {
                startStopButton.isEnabled = true
                showError(msg: "Failed to create the recording directory.")
                return
            }
            logRecordingStartStep("files", startClock: startClock)

            sessionQueue.async {
                self.resetRecordingSamplingState()
                self.arkitLastRecordSlot = nil
                self.recordingFailure = nil

                let arSettings = self.recorderSettings.arkitCamera
                let captureFPS = self.arkitActiveFrameRate()
                let targetFPS = self.targetRecordingFrameRate(for: arSettings)
                let resolution = self.arkitActiveResolution()

                if let device = self.arkitCaptureDevice {
                    do {
                        try self.configureARKitDeviceForPreview(device, settings: arSettings)
                    } catch {
                        os_log("Failed to apply ARKit recording settings: %@", type: .error, error.localizedDescription)
                    }
                }

                self.arkitRecorder = ARKitFrameRecorder(
                    videoURL: self.outDirURL.appendingPathComponent("wide.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("arkit_pose.csv"),
                    targetFrameRate: targetFPS,
                    captureFrameRate: captureFPS
                )
                self.arkitRecorder?.writeDeviceFormat(resolution: resolution)
                self.logRecordingStartStep("arkit_recorder", startClock: startClock)

                let sensorOptions = SensorStreamRecorder.Options(
                    imuEnabled: self.recorderSettings.imuEnabled,
                    deviceMotionEnabled: self.recorderSettings.deviceMotionEnabled,
                    magnetometerEnabled: self.recorderSettings.magnetometerEnabled,
                    barometerEnabled: self.recorderSettings.barometerEnabled
                )
                if sensorOptions.imuEnabled || sensorOptions.deviceMotionEnabled || sensorOptions.magnetometerEnabled || sensorOptions.barometerEnabled {
                    let sensorRecorder = SensorStreamRecorder()
                    sensorRecorder.start(in: self.outDirURL, options: sensorOptions)
                    self.sensorRecorder = sensorRecorder
                }
                self.logRecordingStartStep("sensors", startClock: startClock)

                if self.recorderSettings.audioEnabled {
                    self.audioRecorder = AudioStreamRecorder(
                        audioURL: self.outDirURL.appendingPathComponent("audio.m4a"),
                        infoURL: self.outDirURL.appendingPathComponent("audio_info.csv")
                    )
                    self.audioRecorder?.onFailure = { [weak self] reason in self?.sessionQueue.async { self?.reportRecordingFailure(reason) } }
                }
                self.logRecordingStartStep("audio_recorder", startClock: startClock)

                if self.recorderSettings.lidarDepthEnabled,
                   ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    self.lidarDepthRecorder = LiDARDepthStreamRecorder(outputDirectory: self.outDirURL)
                }
                self.logRecordingStartStep("lidar_depth_recorder", startClock: startClock)

                DispatchQueue.main.async {
                    self.startTime = Date()
                    self.freeRecordingLimitStopRequested = false
                    self.toggleRecording(val: true)
                    if UIApplication.shared.applicationState == .background { self.recordingAppDidEnterBackground(); return }
                    if self.recorderSettings.geoLocationEnabled {
                        self.startLocationRecording()
                    }
                    self.updateTime()
                    self.recordingTimer = Timer.scheduledTimer(
                        timeInterval: 1.0,
                        target: self,
                        selector: #selector(self.updateTime),
                        userInfo: nil,
                        repeats: true
                    )
                    self.startStopButton.isEnabled = true
                    self.logRecordingStartStep("ui_recording", startClock: startClock)
                }
            }
            return
        }

        let captureSessionReady = needsRunningCaptureSession ? (session.isRunning && !session.isInterrupted) : true
        guard isConfigured && captureSessionReady else {
            startStopButton.isEnabled = true
            showError(msg: needsRunningCaptureSession ? "Capture session is not ready yet." : "Recorder is not ready yet.")
            return
        }

        if let issue = standardConfigurationIssue(recorderSettings) {
            startStopButton.isEnabled = true
            showError(msg: issue)
            return
        }

        guard createFiles() else {
            startStopButton.isEnabled = true
            showError(msg: "Failed to create the recording directory.")
            return
        }
        logRecordingStartStep("files", startClock: startClock)

        sessionQueue.async {
            if let issue = self.activeStandardConfigurationIssue() {
                self.writeCaptureMetaJSON(state: "failed")
                DispatchQueue.main.async {
                    self.startStopButton.isEnabled = true
                    self.showError(msg: issue)
                }
                return
            }
            self.resetRecordingSamplingState()
            self.recordingFailure = nil
            self.synchronizationGroup = 0
            self.synchronizationDroppedGroups = 0
            self.synchronizationMaxSkew = 0
            self.synchronizationOrigin = nil
            self.synchronizationOriginSensorSec = nil
            self.initialRecordingSamples.removeAll()
            self.timestampAlignmentSummary = nil
            if self.standardSynchronizer != nil {
                self.synchronizationWriter = SensorCSVWriter(url: self.outDirURL.appendingPathComponent("synchronization.csv"), header: "group_index,reference_sensor_sec,wide_sensor_sec,ultra_sensor_sec,telephoto_sensor_sec,front_sensor_sec,max_skew_sec")
            }

            if self.recorderSettings.wide.enabled {
                self.wideRecorder = CameraStreamRecorder(
                    cameraName: "wide",
                    videoURL: self.outDirURL.appendingPathComponent("wide.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("wide_info.csv"),
                    includeAudioTrack: self.embedAudioInCameraMP4 && self.recorderSettings.audioEnabled,
                    targetFrameRate: self.targetRecordingFrameRate(for: self.recorderSettings.wide),
                    captureFrameRate: self.multiCameraGraph?.request.fps ?? self.activeFrameRate(for: self.wideDevice, settings: self.recorderSettings.wide),
                    hardwareSynchronized: self.multiCameraGraph?.hardwareSyncCameras.contains(.wide) == true
                )
                self.wideRecorder?.expectedResolution = self.recorderSettings.wide.resolution
                self.wideRecorder?.onFailure = { [weak self] reason in self?.sessionQueue.async { self?.reportRecordingFailure(reason) } }
                self.wideRecorder?.writeDeviceFormat(self.multiCameraGraph?.controllers[.wide] ?? self.wideDevice)
            }

            if self.recorderSettings.ultraWide.enabled {
                self.ultraWideRecorder = CameraStreamRecorder(
                    cameraName: "ultrawide",
                    videoURL: self.outDirURL.appendingPathComponent("ultrawide.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("ultra_info.csv"),
                    includeAudioTrack: self.embedAudioInCameraMP4 && self.recorderSettings.audioEnabled,
                    targetFrameRate: self.targetRecordingFrameRate(for: self.recorderSettings.ultraWide),
                    captureFrameRate: self.multiCameraGraph?.request.fps ?? self.activeFrameRate(for: self.ultraWideDevice, settings: self.recorderSettings.ultraWide),
                    hardwareSynchronized: self.multiCameraGraph?.hardwareSyncCameras.contains(.ultraWide) == true
                )
                self.ultraWideRecorder?.expectedResolution = self.recorderSettings.ultraWide.resolution
                self.ultraWideRecorder?.onFailure = { [weak self] reason in self?.sessionQueue.async { self?.reportRecordingFailure(reason) } }
                self.ultraWideRecorder?.writeDeviceFormat(self.multiCameraGraph?.controllers[.ultraWide] ?? self.ultraWideDevice)
            }

            if self.recorderSettings.telephoto.enabled {
                self.telephotoRecorder = CameraStreamRecorder(
                    cameraName: "telephoto",
                    videoURL: self.outDirURL.appendingPathComponent("telephoto.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("tele_info.csv"),
                    includeAudioTrack: self.embedAudioInCameraMP4 && self.recorderSettings.audioEnabled,
                    targetFrameRate: self.targetRecordingFrameRate(for: self.recorderSettings.telephoto),
                    captureFrameRate: self.multiCameraGraph?.request.fps ?? self.activeFrameRate(for: self.telephotoDevice, settings: self.recorderSettings.telephoto),
                    hardwareSynchronized: self.multiCameraGraph?.hardwareSyncCameras.contains(.telephoto) == true
                )
                self.telephotoRecorder?.expectedResolution = self.recorderSettings.telephoto.resolution
                self.telephotoRecorder?.onFailure = { [weak self] reason in self?.sessionQueue.async { self?.reportRecordingFailure(reason) } }
                self.telephotoRecorder?.writeDeviceFormat(self.multiCameraGraph?.controllers[.telephoto] ?? self.telephotoDevice)
            }

            if self.recorderSettings.front.enabled {
                self.frontRecorder = CameraStreamRecorder(
                    cameraName: "front",
                    videoURL: self.outDirURL.appendingPathComponent("front.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("front_info.csv"),
                    includeAudioTrack: self.embedAudioInCameraMP4 && self.recorderSettings.audioEnabled,
                    targetFrameRate: self.targetRecordingFrameRate(for: self.recorderSettings.front),
                    captureFrameRate: self.multiCameraGraph?.request.fps ?? self.activeFrameRate(for: self.frontDevice, settings: self.recorderSettings.front),
                    hardwareSynchronized: self.multiCameraGraph?.hardwareSyncCameras.contains(.front) == true
                )
                self.frontRecorder?.expectedResolution = self.recorderSettings.front.resolution
                self.frontRecorder?.onFailure = { [weak self] reason in self?.sessionQueue.async { self?.reportRecordingFailure(reason) } }
                self.frontRecorder?.writeDeviceFormat(self.multiCameraGraph?.controllers[.front] ?? self.frontDevice)
            }
            self.wideRecorder?.noteSDKRecommendations(self.widePreviewOutput)
            self.ultraWideRecorder?.noteSDKRecommendations(self.ultraWidePreviewOutput)
            self.telephotoRecorder?.noteSDKRecommendations(self.telephotoPreviewOutput)
            self.frontRecorder?.noteSDKRecommendations(self.frontPreviewOutput)
            self.logRecordingStartStep("camera_recorders", startClock: startClock)


            if self.recorderSettings.audioEnabled {
                self.audioRecorder = AudioStreamRecorder(
                    audioURL: self.outDirURL.appendingPathComponent("audio.m4a"),
                    infoURL: self.outDirURL.appendingPathComponent("audio_info.csv")
                )
                self.audioRecorder?.onFailure = { [weak self] reason in self?.sessionQueue.async { self?.reportRecordingFailure(reason) } }
            }
            self.logRecordingStartStep("audio_recorder", startClock: startClock)

            if self.recorderSettings.lidarDepthEnabled && self.lidarDepthOutput != nil {
                self.lidarDepthRecorder = LiDARDepthStreamRecorder(outputDirectory: self.outDirURL)
            }
            self.logRecordingStartStep("lidar_depth_recorder", startClock: startClock)

            let sensorOptions = SensorStreamRecorder.Options(
                imuEnabled: self.recorderSettings.imuEnabled,
                deviceMotionEnabled: self.recorderSettings.deviceMotionEnabled,
                magnetometerEnabled: self.recorderSettings.magnetometerEnabled,
                barometerEnabled: self.recorderSettings.barometerEnabled
            )
            if sensorOptions.imuEnabled || sensorOptions.deviceMotionEnabled || sensorOptions.magnetometerEnabled || sensorOptions.barometerEnabled {
                let sensorRecorder = SensorStreamRecorder()
                sensorRecorder.start(in: self.outDirURL, options: sensorOptions)
                self.sensorRecorder = sensorRecorder
            }
            self.logRecordingStartStep("sensors", startClock: startClock)

            // Samples captured during synchronous encoder/sensor preparation
            // may already be queued. They belong to preview, not this recording.
            self.recordingAdmissionSensorSec = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            self.captureRecordingActive = true
            DispatchQueue.main.async {
                self.startTime = Date()
                self.freeRecordingLimitStopRequested = false
                self.toggleRecording(val: true)
                if UIApplication.shared.applicationState == .background { self.recordingAppDidEnterBackground(); return }
                if self.recorderSettings.geoLocationEnabled {
                    self.startLocationRecording()
                }
                self.updateTime()
                self.recordingTimer = Timer.scheduledTimer(
                    timeInterval: 1.0,
                    target: self,
                    selector: #selector(self.updateTime),
                    userInfo: nil,
                    repeats: true
                )
                self.startStopButton.isEnabled = true
                self.logRecordingStartStep("ui_recording", startClock: startClock)
            }
        }
    }

    private func logRecordingStartStep(_ step: String, startClock: CFTimeInterval) {
        let elapsed = CACurrentMediaTime() - startClock
        os_log("REC_START %{public}@ %.3fs", type: .info, step, elapsed)
    }

    private func stopRecording(showUpgradePromptAfterFinish: Bool = false) {
        guard isRecording, recordingTransition != .finishing else { return }
        recordingTransition = .finishing
        toggleRecording(val: false)
        startStopButton.isEnabled = false
        startStopButton.accessibilityValue = "finishing"
        recordingTimer?.invalidate()
        recordingTimer = nil
        sensorRecorder?.stop()
        sensorRecorder = nil
        stopLocationRecording()
        timeWriteLabel.text = "mp4,csv"

        sessionQueue.async {
            self.captureRecordingActive = false
            self.resetRecordingSamplingState()
            let group = DispatchGroup()
            if let wideRecorder = self.wideRecorder {
                group.enter()
                wideRecorder.finish { group.leave() }
            }
            if let ultraWideRecorder = self.ultraWideRecorder {
                group.enter()
                ultraWideRecorder.finish { group.leave() }
            }
            if let telephotoRecorder = self.telephotoRecorder {
                group.enter()
                telephotoRecorder.finish { group.leave() }
            }
            if let frontRecorder = self.frontRecorder {
                group.enter()
                frontRecorder.finish { group.leave() }
            }
            if let audioRecorder = self.audioRecorder {
                group.enter()
                audioRecorder.finish { group.leave() }
            }
            self.arkitFrameQueue.sync {
                if let arkitRecorder = self.arkitRecorder {
                    group.enter()
                    arkitRecorder.finish { group.leave() }
                }
            }
            self.arkitDepthQueue.sync {
                self.lidarDepthRecorder?.finish()
            }
            group.notify(queue: self.sessionQueue) {
                self.synchronizationWriter?.close()
                self.synchronizationWriter = nil
                if self.recorderSettings.captureMode == .standard && self.recorderSettings.front.enabled && self.enabledCameraCount(in: self.recorderSettings) > 1 {
                    do {
                        var streams: [String: [TimestampAlignment.Sample]] = [:]
                        for camera in self.enabledPhysicalCameras(self.recorderSettings) {
                            let key = camera == .telephoto ? "tele" : camera.settingsKey
                            streams[key] = try TimestampAlignment.load(self.outDirURL.appendingPathComponent("\(key)_info.csv"))
                        }
                        self.timestampAlignmentSummary = try TimestampAlignment.write(streams: streams, to: self.outDirURL.appendingPathComponent("timestamp_alignment.csv"))
                    } catch { self.reportRecordingFailure("Could not write the timestamp alignment index: \(error.localizedDescription)") }
                }
                self.writeCaptureMetaJSON(state: self.recordingFailure == nil ? "finished" : "failed")
                self.wideRecorder = nil
                self.ultraWideRecorder = nil
                self.telephotoRecorder = nil
                self.frontRecorder = nil
                self.audioRecorder = nil
                self.lidarDepthRecorder = nil
                self.arkitRecorder = nil
                self.arkitLastRecordSlot = nil
                DispatchQueue.main.async {
                    self.recordingTransition = .none
                    self.startStopButton.isEnabled = true
                    self.startStopButton.accessibilityValue = "idle"
                    self.endRecordingBackgroundTask()
                    self.updateSize()
                    if showUpgradePromptAfterFinish {
                        self.showFreeRecordingLimitAlert()
                    }
                }
            }
        }
    }

    private func openCaptureDirectory() {
        guard !isRecording, recordingTransition == .none else { return }
        var sharedURL = URLComponents(url: getRecDir(), resolvingAgainstBaseURL: false)!
        sharedURL.scheme = "shareddocuments"
        UIApplication.shared.open(sharedURL.url!)
    }

    private func toggleRecording(val: Bool) {
        isRecording = val
        if val { recordingTransition = .none }
        updateRecordButtonAppearance(isRecording: val)
        updateAuxiliaryRailButtons(isRecording: val)
        captureStatusBadges["summary"]?.isHidden = !val
        val ? startRECBlinking() : stopRECBlinking()
        if !val {
            hideFreeCountdown()
        }
        refreshOverlayStatus()
        if val {
            fpsStepper.isEnabled = false
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            fpsStepper.isEnabled = true
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func updateRecordButtonAppearance(isRecording: Bool) {
        startStopButton.accessibilityValue = isRecording ? "recording" : "idle"
        var config = startStopButton.configuration
        config?.image = UIImage(systemName: isRecording ? "stop.fill" : "circle.fill")
        config?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        config?.baseBackgroundColor = isRecording ? UIColor.systemRed.withAlphaComponent(0.95) : UIColor.systemRed.withAlphaComponent(0.86)
        config?.baseForegroundColor = .white
        config?.cornerStyle = .capsule
        config?.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        startStopButton.configuration = config
        startStopButton.layer.cornerRadius = 34
        startStopButton.layer.cornerCurve = .continuous
        startStopButton.clipsToBounds = false
    }

    private func updateAuxiliaryRailButtons(isRecording: Bool) {
        let unavailable = isRecording || recordingTransition != .none
        [settingsRailButton, filesRailButton].forEach { button in
            button?.isEnabled = !unavailable
            button?.alpha = unavailable ? 0.28 : 1.0
        }
    }

    private func startRECBlinking() {
        recBlinkTimer?.invalidate()
        recBlinkVisible = true
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recBlinkVisible.toggle()
            self.updateCaptureSummaryLabel()
        }
        recBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRECBlinking() {
        recBlinkTimer?.invalidate()
        recBlinkTimer = nil
        recBlinkVisible = true
        updateCaptureSummaryLabel()
    }

    @IBAction func fpsStepperChanged(_ sender: UIStepper) {
        fpsStepper.value = 30
        fpsLabel.text = "30.0 FPS"
    }

    private func installLandscapeOverlay() {
        legacyControlPanel = startStopButton.superview
        legacyControlPanel?.isHidden = true

        sceneView.backgroundColor = .black

        let wideBadge = makeHUDLabelBadge()
        let ultraBadge = makeHUDLabelBadge()
        let telephotoBadge = makeHUDLabelBadge()
        let frontBadge = makeHUDLabelBadge()
        let depthBadge = makeHUDLabelBadge()
        let summaryBadge = makeTransparentHUDLabel(textColor: .systemRed)
        sceneView.addSubview(wideBadge)
        sceneView.addSubview(ultraBadge)
        sceneView.addSubview(telephotoBadge)
        sceneView.addSubview(frontBadge)
        sceneView.addSubview(depthBadge)
        view.addSubview(summaryBadge)
        cameraStatusBadges["wide"] = wideBadge
        cameraStatusBadges["ultra"] = ultraBadge
        cameraStatusBadges["telephoto"] = telephotoBadge
        cameraStatusBadges["front"] = frontBadge
        cameraStatusBadges["depth"] = depthBadge
        captureStatusBadges["summary"] = summaryBadge
        summaryBadge.isHidden = true
        cameraStatusRows["wide"] = wideBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        cameraStatusRows["ultra"] = ultraBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        cameraStatusRows["telephoto"] = telephotoBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        cameraStatusRows["front"] = frontBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        cameraStatusRows["depth"] = depthBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        captureStatusRows["summary"] = summaryBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first

        // Mode badge — shows capture mode + tracking state
        let modeBadgeView = UIView()
        modeBadgeView.translatesAutoresizingMaskIntoConstraints = false
        modeBadgeView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        modeBadgeView.layer.cornerRadius = 14
        modeBadgeView.layer.cornerCurve = .continuous
        modeBadgeView.layer.borderWidth = 1
        modeBadgeView.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        view.addSubview(modeBadgeView)
        let modeLabel = UILabel()
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        modeLabel.textColor = .white
        modeLabel.textAlignment = .center
        modeBadgeView.addSubview(modeLabel)
        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: modeBadgeView.leadingAnchor, constant: 12),
            modeLabel.trailingAnchor.constraint(equalTo: modeBadgeView.trailingAnchor, constant: -12),
            modeLabel.topAnchor.constraint(equalTo: modeBadgeView.topAnchor, constant: 4),
            modeLabel.bottomAnchor.constraint(equalTo: modeBadgeView.bottomAnchor, constant: -4),

            modeBadgeView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            modeBadgeView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
        ])
        modeBadge = modeBadgeView
        modeBadgeLabel = modeLabel

        let countdownLabel = UILabel()
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.isHidden = true
        countdownLabel.textAlignment = .center
        countdownLabel.font = UIFont.monospacedSystemFont(ofSize: 20, weight: .bold)
        countdownLabel.textColor = .white
        countdownLabel.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        countdownLabel.layer.cornerRadius = 16
        countdownLabel.layer.cornerCurve = .continuous
        countdownLabel.layer.masksToBounds = true
        countdownLabel.layer.borderWidth = 1
        countdownLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        view.addSubview(countdownLabel)
        freeCountdownLabel = countdownLabel
        NSLayoutConstraint.activate([
            countdownLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -22),
            countdownLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            countdownLabel.heightAnchor.constraint(equalToConstant: 52)
        ])

        let sensorBar = UIView()
        sensorBar.translatesAutoresizingMaskIntoConstraints = false
        sensorBar.backgroundColor = .clear
        view.addSubview(sensorBar)
        sensorMonitorBar = sensorBar

        let sensorStack = UIStackView()
        sensorStack.translatesAutoresizingMaskIntoConstraints = false
        sensorStack.axis = .horizontal
        sensorStack.alignment = .center
        sensorStack.distribution = .equalSpacing
        sensorStack.spacing = 8
        sensorBar.addSubview(sensorStack)

        let monitorTitle = UILabel()
        monitorTitle.text = ""
        monitorTitle.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        monitorTitle.textColor = UIColor.white.withAlphaComponent(0.74)
        monitorTitle.textAlignment = .center
        sensorBar.addSubview(monitorTitle)

        NSLayoutConstraint.activate([
            sensorBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 54),
            sensorBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -112),
            sensorBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),
            sensorBar.heightAnchor.constraint(equalToConstant: 34),

            monitorTitle.leadingAnchor.constraint(equalTo: sensorBar.leadingAnchor, constant: 16),
            monitorTitle.trailingAnchor.constraint(equalTo: sensorBar.trailingAnchor, constant: -16),
            monitorTitle.topAnchor.constraint(equalTo: sensorBar.topAnchor),

            sensorStack.leadingAnchor.constraint(equalTo: sensorBar.leadingAnchor, constant: 8),
            sensorStack.trailingAnchor.constraint(equalTo: sensorBar.trailingAnchor, constant: -8),
            sensorStack.centerYAnchor.constraint(equalTo: sensorBar.centerYAnchor)
        ])

        addSensorPill(to: sensorStack, key: "imu", title: "IMU")
        addSensorPill(to: sensorStack, key: "mag", title: "Mag")
        addSensorPill(to: sensorStack, key: "baro", title: "Baro")
        addSensorPill(to: sensorStack, key: "geo", title: "GeoLoc")
        addSensorPill(to: sensorStack, key: "motion", title: "Motion")
        addSensorPill(to: sensorStack, key: "audio", title: "Audio")
        addSensorPill(to: sensorStack, key: "depth", title: "Depth")

        let rightRail = UIView()
        rightRail.translatesAutoresizingMaskIntoConstraints = false
        rightRail.backgroundColor = .clear
        view.addSubview(rightRail)
        rightControlRail = rightRail
        NSLayoutConstraint.activate([
            rightRail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            rightRail.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            rightRail.widthAnchor.constraint(equalToConstant: 92),
            rightRail.heightAnchor.constraint(equalToConstant: 288)
        ])

        let railStack = UIStackView()
        railStack.translatesAutoresizingMaskIntoConstraints = false
        railStack.axis = .vertical
        railStack.alignment = .center
        railStack.distribution = .equalSpacing
        rightRail.addSubview(railStack)
        NSLayoutConstraint.activate([
            railStack.leadingAnchor.constraint(equalTo: rightRail.leadingAnchor, constant: 10),
            railStack.trailingAnchor.constraint(equalTo: rightRail.trailingAnchor, constant: -10),
            railStack.topAnchor.constraint(equalTo: rightRail.topAnchor, constant: 18),
            railStack.bottomAnchor.constraint(equalTo: rightRail.bottomAnchor, constant: -18)
        ])

        let settingsButton = makeRailButton(icon: "gearshape.fill", tint: .white)
        settingsButton.accessibilityIdentifier = "main.settings"
        settingsButton.addTarget(self, action: #selector(showSettingsOverlay), for: .touchUpInside)
        railStack.addArrangedSubview(settingsButton)
        settingsRailButton = settingsButton

        let recordButton = makeRailButton(icon: "circle.fill", tint: .white)
        recordButton.accessibilityIdentifier = "record.toggle"
        var recordConfig = recordButton.configuration
        recordConfig?.baseBackgroundColor = UIColor.systemRed.withAlphaComponent(0.86)
        recordConfig?.cornerStyle = .capsule
        recordButton.configuration = recordConfig
        recordButton.addTarget(self, action: #selector(startStopButtonPressed(_:)), for: .touchUpInside)
        railStack.addArrangedSubview(recordButton)
        startStopButton = recordButton
        updateRecordButtonAppearance(isRecording: false)

        let filesButton = makeRailButton(icon: "folder.fill", tint: .white)
        filesButton.addTarget(self, action: #selector(openLastCaptureDirectory), for: .touchUpInside)
        railStack.addArrangedSubview(filesButton)
        filesRailButton = filesButton
    }

    private func makeHUDLabelBadge() -> UIView {
        let badge = UIView()
        badge.backgroundColor = .clear
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.85
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: badge.topAnchor),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor)
        ])
        return badge
    }

    private func makeTransparentHUDLabel(textColor: UIColor) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        label.textColor = textColor
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }

    private func addSensorPill(to stack: UIStackView, key: String, title: String) {
        let label = UILabel()
        label.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.44)
        label.text = "\(title) 0Hz"
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.76
        label.textAlignment = .center
        stack.addArrangedSubview(label)
        sensorStatusRows[key] = label
    }

    private func makeRailButton(icon: String, tint: UIColor) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: icon)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        config.baseForegroundColor = tint
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 34
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 68),
            button.heightAnchor.constraint(equalToConstant: 68)
        ])
        return button
    }

    @objc private func openLastCaptureDirectory() {
        openCaptureDirectory()
    }


    private func addSettingsCard(to stack: UIStackView, title: String, icon: String, identifier: String) -> UIStackView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.backgroundColor = UIColor(white: 0.105, alpha: 1)
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        card.accessibilityIdentifier = "settings.card.\(identifier)"
        let heading = UIStackView()
        heading.axis = .horizontal
        heading.spacing = 9
        heading.alignment = .center
        let image = UIImageView(image: UIImage(systemName: icon))
        image.tintColor = UIColor.white.withAlphaComponent(0.65)
        image.contentMode = .scaleAspectFit
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true
        image.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        enableSettingsTextWrapping(label)
        heading.addArrangedSubview(image)
        heading.addArrangedSubview(label)
        card.addArrangedSubview(heading)
        stack.addArrangedSubview(card)
        return card
    }

    private func addFocusModeControl(to stack: UIStackView, keyPrefix: String, automatic: Bool, manualTitle: String) {
        let state = UISwitch()
        state.isOn = automatic
        state.accessibilityIdentifier = "\(keyPrefix).autoFocus"
        settingsSwitches["\(keyPrefix).autoFocus"] = state
        let control = UISegmentedControl(items: ["Auto", manualTitle])
        control.accessibilityIdentifier = "settings.focusMode.\(keyPrefix)"
        control.selectedSegmentIndex = automatic ? 0 : 1
        control.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.17)
        control.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        control.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: UIColor.white], for: .normal)
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        control.addTarget(self, action: #selector(focusModeSelectionChanged(_:)), for: .valueChanged)
        stack.addArrangedSubview(control)
    }

    @objc private func focusModeSelectionChanged(_ sender: UISegmentedControl) {
        guard let prefix = sender.accessibilityIdentifier?.replacingOccurrences(of: "settings.focusMode.", with: ""),
              let state = settingsSwitches["\(prefix).autoFocus"] else { return }
        state.isOn = sender.selectedSegmentIndex == 0
        autoFocusSwitchChanged(state)
    }

    private func addSettingsHeader(to stack: UIStackView) {
        let titleLabel = UILabel()
        titleLabel.text = "Settings"
        titleLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        enableSettingsTextWrapping(titleLabel)

        stack.addArrangedSubview(titleLabel)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 16)
        cancel.accessibilityIdentifier = "settings.close"
        cancel.addTarget(self, action: #selector(hideSettingsOverlay), for: .touchUpInside)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(cancel)
    }

    private func addSettingsFootnote(to stack: UIStackView, text: String) {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = UIColor.white.withAlphaComponent(0.65)
        enableSettingsTextWrapping(label)
        stack.addArrangedSubview(label)
    }

    private func enableSettingsTextWrapping(_ label: UILabel) {
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func enableSettingsButtonTextWrapping(_ button: UIButton) {
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }


    private func addSettingsMenuRow(
        to stack: UIStackView,
        key: String,
        title: String,
        items: [String],
        selectedValue: String,
        compact: Bool = false,
        vertical: Bool = false,
        onChange: ((String) -> Void)? = nil
    ) {
        let row = UIStackView()
        row.axis = vertical ? .vertical : .horizontal
        row.alignment = vertical ? .fill : .center
        row.spacing = vertical ? 7 : 12

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: vertical ? 14 : 16, weight: vertical ? .regular : .medium)
        titleLabel.textColor = vertical ? UIColor.white.withAlphaComponent(0.65) : .white
        enableSettingsTextWrapping(titleLabel)
        if !vertical { titleLabel.widthAnchor.constraint(equalToConstant: compact ? 112 : 126).isActive = true }

        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .leading
        enableSettingsButtonTextWrapping(button)
        button.accessibilityValue = resolvedSelectedValue(in: items, preferred: selectedValue)
        button.accessibilityIdentifier = "settings.menu.\(key)"
        button.configuration = settingsMenuConfiguration(title: button.accessibilityValue ?? selectedValue, compact: compact)
        button.menu = UIMenu(children: items.map { item in
            UIAction(title: item, state: item == button.accessibilityValue ? .on : .off) { [weak self, weak button] _ in
                button?.accessibilityValue = item
                button?.configuration = self?.settingsMenuConfiguration(title: item, compact: compact)
                onChange?(item)
                self?.settingsFormatSelectionChanged(key)
            }
        })
        button.showsMenuAsPrimaryAction = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        settingsMenuButtons[key] = button

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(button)
        stack.addArrangedSubview(row)
    }

    private func addSettingsSliderRow(
        to stack: UIStackView,
        key: String,
        title: String,
        value: Double,
        compact: Bool = false
    ) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = compact ? 10 : 16

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: compact ? 15 : 17, weight: .semibold)
        titleLabel.textColor = .white
        enableSettingsTextWrapping(titleLabel)
        titleLabel.widthAnchor.constraint(equalToConstant: compact ? 112 : 126).isActive = true

        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = Float(clampedLensPosition(value))
        slider.minimumTrackTintColor = .systemTeal
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
        slider.accessibilityIdentifier = key
        slider.addTarget(self, action: #selector(settingsSliderChanged(_:)), for: .valueChanged)

        let valueLabel = UILabel()
        valueLabel.text = String(format: "%.2f", slider.value)
        valueLabel.font = UIFont.monospacedSystemFont(ofSize: compact ? 13 : 14, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .right
        enableSettingsTextWrapping(valueLabel)
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        settingsSliders[key] = slider
        settingsSliderValueLabels[key] = valueLabel

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(row)
    }

    @objc private func settingsSliderChanged(_ sender: UISlider) {
        guard let key = sender.accessibilityIdentifier else { return }
        settingsSliderValueLabels[key]?.text = String(format: "%.2f", sender.value)
    }


    private func settingsFormatSelectionChanged(_ key: String) {
        if key.hasSuffix(".resolution") || key.hasSuffix(".frameRate") || key == "shared.maxExposure" {
            updateCameraResolutionMenus()
        }
    }

    private func addCameraSettingsSection(
        to stack: UIStackView,
        title: String,
        keyPrefix: String,
        settings: CameraCaptureSettings,
        resolutionItems: [String],
        defaultLensPosition: Double,
        available: Bool,
        unavailableReason: String? = nil
    ) {
        if !title.isEmpty { addSettingsSubsectionTitle(
            to: stack,
            title: title,
            enabled: available,
            detail: unavailableReason
        ) }
        let compactStack = UIStackView()
        compactStack.axis = .vertical
        compactStack.spacing = 6
        compactStack.layoutMargins = .zero
        compactStack.isLayoutMarginsRelativeArrangement = true
        stack.addArrangedSubview(compactStack)
        cameraSettingsGroups[keyPrefix] = compactStack
        let captureControls = UIStackView()
        captureControls.axis = .vertical
        captureControls.spacing = 8
        compactStack.addArrangedSubview(captureControls)
        if keyPrefix == "arkit" {
        addSettingsMenuRow(
            to: captureControls,
            key: "\(keyPrefix).resolution",
            title: "Resolution",
            items: resolutionItems,
            selectedValue: settings.resolution,
            compact: true
        )
        addSettingsMenuRow(
            to: captureControls,
            key: "\(keyPrefix).frameRate",
            title: "Hz",
            items: keyPrefix == "arkit" ? ["1", "5", "10", "20", "30", "60"] : [],
            selectedValue: settings.frameRate,
            compact: true
        )
        addSettingsRow(
            to: captureControls,
            key: "\(keyPrefix).autoExposure",
            title: "Auto Exposure",
            detail: "",
            isOn: isAutoExposureEnabled(for: settings),
            compact: true
        )
        addSettingsMenuRow(
            to: captureControls,
            key: "\(keyPrefix).maxExposure",
            title: "Max Exposure",
            items: ["1", "5", "10", "20", "30"],
            selectedValue: maxExposureDurationLabel(for: settings),
            compact: true
        )
        }
        if keyPrefix != "arkit", let device = settingsDevice(keyPrefix, settings: settingsDraft()),
           !device.isLockingFocusWithCustomLensPositionSupported {
            addSettingsFootnote(to: compactStack, text: "Fixed-focus lens; manual focus position is unavailable.")
            return
        }
        addFocusModeControl(to: compactStack, keyPrefix: keyPrefix, automatic: settings.autoFocus, manualTitle: "Manual")
        addSettingsSliderRow(
            to: compactStack,
            key: "\(keyPrefix).fixedFocus",
            title: "Focus Position",
            value: clampedLensPosition(settings.fixedFocusLensPosition, fallback: defaultLensPosition),
            compact: true
        )
        updateAutoExposureControlState(keyPrefix: keyPrefix, cameraEnabled: settings.enabled && available)
        updateFixedFocusControlState(keyPrefix: keyPrefix, cameraEnabled: settings.enabled && available)
        updateCameraSettingsGroup(keyPrefix: keyPrefix, enabled: settings.enabled && available)
    }

    private func addSettingsSubsectionTitle(
        to stack: UIStackView,
        title: String,
        enabled: Bool = true,
        detail: String? = nil
    ) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 1

        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        label.textColor = enabled ? .white : UIColor.white.withAlphaComponent(0.34)
        enableSettingsTextWrapping(label)
        textStack.addArrangedSubview(label)

        if let detail, !detail.isEmpty {
            let detailLabel = UILabel()
            detailLabel.text = detail
            detailLabel.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            detailLabel.textColor = UIColor.white.withAlphaComponent(0.46)
            enableSettingsTextWrapping(detailLabel)
            textStack.addArrangedSubview(detailLabel)
        }

        row.addArrangedSubview(textStack)

        stack.addArrangedSubview(row)
    }

    private func combinationTitle(_ settings: RecorderSettings) -> String {
        [("Wide", settings.wide.enabled), ("Ultra Wide", settings.ultraWide.enabled),
         ("Telephoto", settings.telephoto.enabled), ("Front", settings.front.enabled)]
            .filter { $0.1 }.map { $0.0 }.joined(separator: " + ")
    }

    private func combinationCandidates(_ base: RecorderSettings) -> [(String, RecorderSettings)] {
        var choices: [(String, RecorderSettings)] = []
        let reference = [base.wide, base.ultraWide, base.telephoto, base.front].first(where: \.enabled) ?? base.wide
        func sharingPolicy(_ camera: CameraCaptureSettings) -> CameraCaptureSettings {
            var camera = camera
            camera.resolution = reference.resolution
            camera.frameRate = reference.frameRate
            camera.autoExposure = reference.autoExposure
            camera.maxExposureDurationMS = reference.maxExposureDurationMS
            camera.autoFocus = reference.autoFocus
            return camera
        }
        let masks = (1..<(1 << PhysicalCamera.allCases.count)).sorted {
            $0.nonzeroBitCount == $1.nonzeroBitCount ? $0 < $1 : $0.nonzeroBitCount < $1.nonzeroBitCount
        }
        for mask in masks {
            var draft = base
            draft.wide = sharingPolicy(draft.wide)
            draft.ultraWide = sharingPolicy(draft.ultraWide)
            draft.telephoto = sharingPolicy(draft.telephoto)
            draft.front = sharingPolicy(draft.front)
            draft.wide.enabled = mask & 1 != 0
            draft.ultraWide.enabled = mask & 2 != 0
            draft.telephoto.enabled = mask & 4 != 0
            draft.front.enabled = mask & 8 != 0
            let cameras = [("wide", draft.wide), ("ultra", draft.ultraWide), ("telephoto", draft.telephoto), ("front", draft.front)].filter { $0.1.enabled }
            guard cameras.allSatisfy({ settingsDevice($0.0, settings: draft) != nil }), isCameraSetSupportedByMultiCam(settings: draft) else { continue }
            choices.append((combinationTitle(draft), draft))
        }
        return choices
    }

    private func sharedFormats(_ settings: RecorderSettings) -> [[AVCaptureDevice.Format]] {
        [("wide", settings.wide), ("ultra", settings.ultraWide), ("telephoto", settings.telephoto), ("front", settings.front)]
            .filter { $0.1.enabled }.map { capabilityFormats($0.0, settings: settings) }
    }

    private func commonResolutionChoices(_ settings: RecorderSettings) -> [String] {
        let lists = sharedFormats(settings).map { Set(resolutionChoices($0)) }
        guard let first = lists.first else { return [] }
        return lists.dropFirst().reduce(first) { $0.intersection($1) }.sorted {
            let a = resolutionSize(from: $0) ?? .zero
            let b = resolutionSize(from: $1) ?? .zero
            return a.width * a.height > b.width * b.height
        }
    }

    private func commonRateChoices(_ settings: RecorderSettings) -> [String] {
        let cameras = [("wide", settings.wide), ("ultra", settings.ultraWide), ("telephoto", settings.telephoto), ("front", settings.front)].filter { $0.1.enabled }
        let lists = cameras.map { key, camera in
            Set(frameRateChoices(capabilityFormats(key, settings: settings).filter { formatResolution($0) == camera.resolution },
                                 ceiling: settings.lidarDepthEnabled ? depthEnabledCameraFrameRateLimit : .greatestFiniteMagnitude))
        }
        guard let first = lists.first else { return [] }
        return lists.dropFirst().reduce(first) { $0.intersection($1) }.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
    }

    private func installCombinationMenu(draft: RecorderSettings, generation: UUID) {
        guard let button = settingsMenuButtons["cameraCombination"] else { return }
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            self.sessionQueue.async {
                let choices: [(String, RecorderSettings)] = self.withRestoredCaptureDevices {
                    self.combinationCandidates(draft).compactMap { title, candidate in
                        // Keep a working draft when possible; otherwise find a verified
                        // common starting point before offering the new combination.
                        if self.jointConfigurationFits(candidate) { return (title, candidate) }
                        for resolution in self.commonResolutionChoices(candidate).reversed() {
                            var seed = self.replacingCaptureValue(candidate, key: "shared.resolution", value: resolution)
                            let rates = self.commonRateChoices(seed)
                            let tries = Array(Set([rates.contains("30") ? "30" : "", rates.first ?? ""])).filter { !$0.isEmpty }
                            for rate in tries {
                                seed = self.replacingCaptureValue(seed, key: "shared.frameRate", value: rate)
                                if self.jointConfigurationFits(seed) { return (title, seed) }
                            }
                        }
                        return nil
                    }
                }
                DispatchQueue.main.async {
                    guard self.settingsCapabilityGeneration == generation, self.settingsOverlayView != nil else { completion([]); return }
                    let groups = Dictionary(grouping: choices) { self.enabledCameraCount(in: $0.1) }
                    completion(groups.keys.sorted().map { count in
                        let title = [1: "Single camera", 2: "Dual cameras", 3: "Triple cameras"][count] ?? "\(count) cameras"
                        let actions = (groups[count] ?? []).map { name, candidate in
                            UIAction(title: name, state: name == self.combinationTitle(draft) ? .on : .off) { [weak self] _ in
                                guard let self, self.settingsCapabilityGeneration == generation else { return }
                                self.confirmCameraCombination(candidate)
                            }
                        }
                        return UIMenu(title: title, options: .displayInline, children: actions)
                    })
                }
            }
        }])
    }

    private func synchronizationDescription(_ settings: RecorderSettings) -> String {
        let cameras = enabledPhysicalCameras(settings)
        let rear = cameras.subtracting([.front])
        if cameras.count <= 1 { return "Single camera" }
        let names = PhysicalCamera.allCases.filter { rear.contains($0) }.map(\.displayName).joined(separator: " + ")
        if !cameras.contains(.front) { return "Hardware sync: \(names)" }
        if rear.count > 1 { return "Rear: hardware sync · Front: timestamp alignment" }
        return "Timestamp alignment · no hardware sync"
    }

    private func confirmCameraCombination(_ candidate: RecorderSettings) {
        guard candidate.front.enabled && enabledCameraCount(in: candidate) > 1 else { rebuildCameraSettings(candidate); return }
        let rear = enabledPhysicalCameras(candidate).subtracting([.front])
        let message = synchronizationDescription(candidate) + "\n\n" + (rear.count > 1
            ? "Only the rear camera views are hardware synchronized. Front records independently; matching timestamps do not guarantee the same exposure instant."
            : "These camera views are not hardware synchronized. Each records original frames independently; alignment uses their capture timestamps.")
        let alert = UIAlertController(title: "Camera Synchronization", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Use This Combination", style: .default) { [weak self] _ in self?.rebuildCameraSettings(candidate) })
        (settingsController ?? self).present(alert, animated: true)
    }

    private func rebuildCameraSettings(_ draft: RecorderSettings) {
        guard let container = settingsCameraContainer else { return }
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let prefixes = ["wide.", "ultra.", "telephoto.", "front.", "arkit.", "shared.", "depth."]
        settingsMenuButtons = settingsMenuButtons.filter { item in !prefixes.contains(where: { item.key.hasPrefix($0) }) && item.key != "cameraCombination" }
        settingsSwitches = settingsSwitches.filter { item in !prefixes.contains(where: { item.key.hasPrefix($0) }) && item.key != "lidarDepth" }
        settingsSliders.removeAll()
        settingsSliderValueLabels.removeAll()
        cameraSettingsGroups.removeAll()
        populateCameraSettings(container: container, isARKMode: false, arkitAvailable: ARWorldTrackingConfiguration.isSupported, configuration: draft)
    }

    private func updateCameraResolutionMenus() {
        guard settingsMenuButtons["captureMode"]?.accessibilityValue != "ARKit" else { return }
        settingsCapabilityGeneration = UUID()
        let generation = settingsCapabilityGeneration
        let draft = settingsDraft()
        settingsSaveButton?.isEnabled = false
        settingsValidationLabel?.text = "Checking configuration…"
        settingsValidationLabel?.isHidden = false
        settingsRetryButton?.isHidden = true
        let valueKeys = ["shared.resolution", "shared.frameRate"]
        for key in valueKeys { settingsMenuButtons[key]?.configuration = settingsMenuConfiguration(title: "Checking…", compact: true) }
        sessionQueue.async {
            let valid = self.withRestoredCaptureDevices { self.jointConfigurationFits(draft) }
            DispatchQueue.main.async {
                guard self.settingsCapabilityGeneration == generation, self.settingsOverlayView != nil else { return }
                self.settingsSaveButton?.isEnabled = valid
                self.settingsValidationLabel?.isHidden = valid
                self.settingsValidationLabel?.text = valid ? nil : "Configuration unavailable. Choose supported values or retry."
                self.settingsValidationLabel?.textColor = .systemOrange
                self.settingsRetryButton?.isHidden = valid
                for key in valueKeys {
                    let title = self.settingsMenuHasCandidates[key] != true ? "Not available"
                        : valid ? self.settingsMenuButtons[key]?.accessibilityValue ?? "Choose…" : "Choose…"
                    self.settingsMenuButtons[key]?.configuration = self.settingsMenuConfiguration(title: title, compact: true)
                }
            }
        }
        installCombinationMenu(draft: draft, generation: generation)
        installVerifiedMenu(key: "shared.resolution", candidates: commonResolutionChoices(draft), draft: draft, generation: generation)
        installVerifiedMenu(key: "shared.frameRate", candidates: commonRateChoices(draft), draft: draft, generation: generation)

    }

    private func updateCameraSettingsGroup(keyPrefix: String, enabled: Bool) {
        guard let group = cameraSettingsGroups[keyPrefix] else { return }
        group.isUserInteractionEnabled = enabled
        group.alpha = enabled ? 1.0 : 0.34
    }

    private func updateAutoExposureControlState(keyPrefix: String, cameraEnabled: Bool) {
        guard let button = settingsMenuButtons["\(keyPrefix).maxExposure"] else { return }
        let autoExposureEnabled = settingsSwitches["\(keyPrefix).autoExposure"]?.isOn ?? true
        let enabled = cameraEnabled && autoExposureEnabled
        button.isEnabled = enabled
        button.alpha = enabled ? 1.0 : 0.6
    }

    private func updateFixedFocusControlState(keyPrefix: String, cameraEnabled: Bool) {
        guard let slider = settingsSliders["\(keyPrefix).fixedFocus"] else { return }
        let autoFocusEnabled = settingsSwitches["\(keyPrefix).autoFocus"]?.isOn ?? false
        let enabled = cameraEnabled && !autoFocusEnabled
        slider.isEnabled = enabled
        slider.superview?.isHidden = autoFocusEnabled
        slider.alpha = enabled ? 1.0 : 0.34
        settingsSliderValueLabels["\(keyPrefix).fixedFocus"]?.alpha = enabled ? 1.0 : 0.34
    }

    private func resolvedSelectedValue(in items: [String], preferred: String) -> String {
        if items.contains(preferred) { return preferred }
        if let requested = Double(preferred), items.allSatisfy({ Double($0) != nil }) {
            return items.min { abs((Double($0) ?? 0) - requested) < abs((Double($1) ?? 0) - requested) } ?? preferred
        }
        return items.first ?? preferred
    }

    private func settingsMenuConfiguration(title: String, compact: Bool = false) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 15, weight: .medium)
            ])
        )
        config.image = UIImage(systemName: "chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.25)
        config.baseForegroundColor = .white
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 10,
            leading: 12,
            bottom: 10,
            trailing: 12
        )
        return config
    }

    private func makeOverlayPanel() -> UIVisualEffectView {
        let effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        let panel = UIVisualEffectView(effect: effect)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 22
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        return panel
    }




    @objc private func showSettingsOverlay() {
        guard settingsOverlayView == nil, !isRecording, recordingTransition == .none, presentedViewController == nil else { return }
        let controller = PortraitSettingsViewController()
        controller.overrideUserInterfaceStyle = .dark
        controller.modalPresentationStyle = .fullScreen
        controller.loadViewIfNeeded()
        controller.view.backgroundColor = .black
        settingsController = controller
        let hostView = controller.view!
        settingsMenuButtons.removeAll()
        settingsSwitches.removeAll()
        settingsSliders.removeAll()
        settingsSliderValueLabels.removeAll()
        cameraSettingsGroups.removeAll()

        let dimView = UIView()
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black
        hostView.addSubview(dimView)
        settingsOverlayView = dimView

        let configPanel = makeOverlayPanel()
        dimView.addSubview(configPanel)
        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: hostView.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

            configPanel.centerXAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.centerXAnchor),
            configPanel.widthAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.widthAnchor, multiplier: 1.0),
            configPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            configPanel.topAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.topAnchor),
            configPanel.bottomAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.bottomAnchor)
        ])

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.indicatorStyle = .white
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        configPanel.contentView.addSubview(scrollView)

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false
        configPanel.contentView.addSubview(header)
        addSettingsHeader(to: header)

        let actionBar = UIStackView()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.axis = .horizontal
        actionBar.alignment = .center
        actionBar.distribution = .fillEqually
        actionBar.spacing = 14
        configPanel.contentView.addSubview(actionBar)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: configPanel.contentView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: configPanel.contentView.trailingAnchor, constant: -24),
            header.leadingAnchor.constraint(equalTo: configPanel.contentView.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: configPanel.contentView.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: configPanel.contentView.topAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -14),

            actionBar.leadingAnchor.constraint(equalTo: configPanel.contentView.leadingAnchor, constant: 24),
            actionBar.trailingAnchor.constraint(equalTo: configPanel.contentView.trailingAnchor, constant: -24),
            actionBar.bottomAnchor.constraint(equalTo: configPanel.contentView.bottomAnchor, constant: -18),
            actionBar.heightAnchor.constraint(equalToConstant: 48),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -12)
        ])

        let arkitAvailable = ARWorldTrackingConfiguration.isSupported
        let initialMode = recorderSettings.captureMode == .arkit && arkitAvailable ? "ARKit" : "Standard"

        // Camera section container — rebuilt when mode changes
        let cameraContainer = UIStackView()
        cameraContainer.axis = .vertical
        cameraContainer.spacing = 10

        addSettingsMenuRow(
            to: stack,
            key: "captureMode",
            title: "Mode",
            items: arkitAvailable ? ["Standard", "ARKit"] : ["Standard"],
            selectedValue: initialMode,
            compact: false,
            onChange: { [weak self, weak cameraContainer] newMode in
                guard let self = self, let cameraContainer = cameraContainer else { return }
                let isARK = newMode == "ARKit"
                self.settingsCapabilityGeneration = UUID()
                self.settingsValidationLabel = nil
                self.settingsSaveButton?.isEnabled = true
                cameraContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
                self.cameraSettingsGroups.removeAll()
                self.settingsSwitches = self.settingsSwitches.filter { !$0.key.hasPrefix("shared.") && !$0.key.hasPrefix("depth.") && $0.key != "lidarDepth" && !$0.key.hasPrefix("wide.") && !$0.key.hasPrefix("ultra.") && !$0.key.hasPrefix("telephoto.") && !$0.key.hasPrefix("front.") && !$0.key.hasPrefix("arkit.") }
                self.settingsSliders = self.settingsSliders.filter { !$0.key.hasPrefix("wide.") && !$0.key.hasPrefix("ultra.") && !$0.key.hasPrefix("telephoto.") && !$0.key.hasPrefix("front.") && !$0.key.hasPrefix("arkit.") }
                self.settingsSliderValueLabels = self.settingsSliderValueLabels.filter { !$0.key.hasPrefix("wide.") && !$0.key.hasPrefix("ultra.") && !$0.key.hasPrefix("telephoto.") && !$0.key.hasPrefix("front.") && !$0.key.hasPrefix("arkit.") }
                self.settingsMenuButtons = self.settingsMenuButtons.filter { $0.key == "captureMode" }
                self.populateCameraSettings(container: cameraContainer, isARKMode: isARK, arkitAvailable: arkitAvailable)
            }
        )
        if !arkitAvailable {
            addSettingsFootnote(to: stack, text: "ARKit is not available on this device. Only Standard mode is supported.")
        }

        stack.addArrangedSubview(cameraContainer)
        self.settingsCameraContainer = cameraContainer
        self.populateCameraSettings(container: cameraContainer, isARKMode: initialMode == "ARKit", arkitAvailable: arkitAvailable)

        let sensors = addSettingsCard(to: stack, title: "Sensors", icon: "waveform.path", identifier: "sensors")
        let sensorRows = [("imu", "IMU", recorderSettings.imuEnabled), ("motion", "Motion", recorderSettings.deviceMotionEnabled),
                          ("mag", "Magnetometer", recorderSettings.magnetometerEnabled), ("baro", "Barometer", recorderSettings.barometerEnabled),
                          ("geo", "Location", recorderSettings.geoLocationEnabled), ("audio", "Audio", recorderSettings.audioEnabled)]
        for index in stride(from: 0, to: sensorRows.count, by: 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 16
            for (key, title, value) in sensorRows[index..<min(index + 2, sensorRows.count)] {
                let column = UIStackView()
                column.axis = .vertical
                addSettingsRow(to: column, key: key, title: title, detail: "", isOn: value, compact: true)
                row.addArrangedSubview(column)
            }
            sensors.addArrangedSubview(row)
        }
        let account = addSettingsCard(to: stack, title: "Account", icon: "person.crop.circle", identifier: "account")
        addPurchaseSection(to: account)
        addSettingsActionButtons(to: actionBar)
        present(controller, animated: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            scrollView.flashScrollIndicators()
        }
    }

    private func populateCameraSettings(container: UIStackView, isARKMode: Bool, arkitAvailable: Bool, configuration: RecorderSettings? = nil) {
        let capabilities = cameraCapabilities()

        if isARKMode {
            let captureCard = addSettingsCard(to: container, title: "AR Camera", icon: "camera", identifier: "camera")
            let arkitResolutionItems = arkitResolutionOptions(for: recorderSettings.arkitCamera.resolution)
            addCameraSettingsSection(
                to: captureCard,
                title: "",
                keyPrefix: "arkit",
                settings: recorderSettings.arkitCamera,
                resolutionItems: arkitResolutionItems,
                defaultLensPosition: defaultARKitFixedFocusLensPosition,
                available: arkitAvailable,
                unavailableReason: arkitAvailable ? nil : "ARKit not available"
            )
            addDepthSettingsCard(to: container, enabled: recorderSettings.lidarDepthEnabled, available: capabilities.hasLiDAR)
        } else {
            let config = configuration ?? recorderSettings
            let cameras = [("wide", "Wide", config.wide, capabilities.hasWide, defaultWideFixedFocusLensPosition),
                           ("ultra", "Ultra Wide", config.ultraWide, capabilities.hasUltraWide, defaultUltraWideFixedFocusLensPosition),
                           ("telephoto", "Telephoto", config.telephoto, capabilities.hasTelephoto, defaultTelephotoFixedFocusLensPosition),
                           ("front", "Front", config.front, capabilities.hasFront, defaultFrontFixedFocusLensPosition)]
            let cameraCard = addSettingsCard(to: container, title: "Camera", icon: "camera", identifier: "camera")
            let validation = UILabel()
            validation.font = .systemFont(ofSize: 13)
            validation.textColor = UIColor.white.withAlphaComponent(0.6)
            enableSettingsTextWrapping(validation)
            settingsValidationLabel = validation
            addSettingsMenuRow(to: cameraCard, key: "cameraCombination", title: "Camera combination", items: [],
                               selectedValue: combinationTitle(config), compact: true, vertical: true)
            for (key, _, camera, available, _) in cameras {
                let state = UISwitch()
                state.isOn = camera.enabled && available
                state.isEnabled = available
                state.accessibilityIdentifier = "\(key).enabled"
                settingsSwitches["\(key).enabled"] = state
            }
            let enabled = cameras.filter { $0.2.enabled && $0.3 }
            if enabled.isEmpty {
                settingsMenuButtons["cameraCombination"]?.configuration = settingsMenuConfiguration(title: "No cameras available", compact: true)
                addSettingsFootnote(to: cameraCard, text: "No camera hardware available.")
            }
            let reference = enabled.first?.2 ?? config.wide
            let synchronizationLabel = UILabel()
            synchronizationLabel.text = synchronizationDescription(config)
            synchronizationLabel.accessibilityIdentifier = "settings.syncSummary"
            synchronizationLabel.font = .systemFont(ofSize: 13)
            synchronizationLabel.textColor = config.front.enabled && enabled.count > 1 ? .systemOrange : UIColor.white.withAlphaComponent(0.6)
            enableSettingsTextWrapping(synchronizationLabel)
            cameraCard.addArrangedSubview(synchronizationLabel)
            cameraCard.addArrangedSubview(validation)
            let retry = makePurchaseButton(title: "Retry", backgroundColor: UIColor.white.withAlphaComponent(0.1), foregroundColor: .white)
            retry.accessibilityIdentifier = "settings.retry"
            retry.isHidden = true
            retry.addTarget(self, action: #selector(recheckCaptureCapabilities), for: .touchUpInside)
            cameraCard.addArrangedSubview(retry)
            settingsRetryButton = retry
            let captureCard = addSettingsCard(to: container, title: "Capture", icon: "slider.horizontal.3", identifier: "capture")
            let dimensions = UIStackView()
            dimensions.axis = .horizontal
            dimensions.distribution = .fillEqually
            dimensions.spacing = 12
            for (key, title, value) in [("shared.resolution", "Resolution", reference.resolution), ("shared.frameRate", "Frame rate", reference.frameRate)] {
                let field = UIStackView()
                field.axis = .vertical
                addSettingsMenuRow(to: field, key: key, title: title, items: [], selectedValue: value, compact: true, vertical: true)
                dimensions.addArrangedSubview(field)
            }
            captureCard.addArrangedSubview(dimensions)
            addSettingsRow(to: captureCard, key: "shared.autoExposure", title: "Auto exposure", detail: "", isOn: isAutoExposureEnabled(for: reference))
            addSettingsMenuRow(to: captureCard, key: "shared.maxExposure", title: "Max exposure (ms)", items: ["1", "5", "10", "20", "30"], selectedValue: maxExposureDurationLabel(for: reference), compact: true, vertical: true)
            updateAutoExposureControlState(keyPrefix: "shared", cameraEnabled: !enabled.isEmpty)
            let focusCard = addSettingsCard(to: container, title: "Focus", icon: "viewfinder", identifier: "focus")
            if enabled.count > 1 {
                if MultiCameraCaptureGraph.inputGroups(for: enabledPhysicalCameras(config))?.contains(where: { $0.device.isFocusModeSupported(.continuousAutoFocus) && $0.device.isFocusModeSupported(.locked) }) == true {
                    addFocusModeControl(to: focusCard, keyPrefix: "shared", automatic: reference.autoFocus, manualTitle: "Lock current focus")
                } else {
                    addSettingsFootnote(to: focusCard, text: "Fixed-focus lenses")
                }
            } else {
                for (key, _, camera, available, lensPosition) in cameras where camera.enabled && available {
                    addCameraSettingsSection(to: focusCard, title: "", keyPrefix: key, settings: camera,
                                             resolutionItems: [], defaultLensPosition: lensPosition,
                                             available: available, unavailableReason: nil)
                }
            }
            addDepthSettingsCard(to: container, enabled: config.lidarDepthEnabled, available: capabilities.hasLiDAR)
                updateCameraResolutionMenus()
        }
    }

    private func addPurchaseSection(to stack: UIStackView) {
        let statusLabel = UILabel()
        statusLabel.accessibilityIdentifier = "purchase.status"
        settingsPurchaseStatusLabel = statusLabel
        statusLabel.text = purchaseStatusText()
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        enableSettingsTextWrapping(statusLabel)
        stack.addArrangedSubview(statusLabel)

        let buttonRow = UIStackView()
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12

        let upgradeButton = makePurchaseButton(
            title: upgradeButtonTitle(),
            backgroundColor: .systemTeal,
            foregroundColor: .black
        )
        upgradeButton.accessibilityIdentifier = "purchase.upgrade"
        upgradeButton.isEnabled = !PurchaseManager.shared.isPremiumUnlocked
        upgradeButton.alpha = PurchaseManager.shared.isPremiumUnlocked ? 0.34 : 1.0
        upgradeButton.addTarget(self, action: #selector(upgradeButtonTapped), for: .touchUpInside)

        let restoreButton = makePurchaseButton(
            title: "Restore Purchase",
            backgroundColor: UIColor.white.withAlphaComponent(0.14),
            foregroundColor: .white
        )
        restoreButton.accessibilityIdentifier = "purchase.restore"
        restoreButton.addTarget(self, action: #selector(restorePurchaseButtonTapped), for: .touchUpInside)

        buttonRow.addArrangedSubview(upgradeButton)
        buttonRow.addArrangedSubview(restoreButton)
        stack.addArrangedSubview(buttonRow)
    }

    private func makePurchaseButton(
        title: String,
        backgroundColor: UIColor,
        foregroundColor: UIColor
    ) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 14, weight: .medium)
            ])
        )
        config.baseBackgroundColor = backgroundColor
        config.baseForegroundColor = foregroundColor
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        button.configuration = config
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func purchaseStatusText() -> String {
        if PurchaseManager.shared.isPremiumUnlocked {
            return "Premium unlocked · Unlimited recordings"
        }
        return "Free version · \(freeRecordingLimitMinutesText()) per recording"
    }

    private func upgradeButtonTitle() -> String {
        if let price = PurchaseManager.shared.premiumDisplayPrice {
            return "Upgrade \(price)"
        }
        return "Upgrade"
    }

    private func freeRecordingLimitMinutesText() -> String {
        if freeRecordingLimitSeconds < 60 {
            return "\(Int(freeRecordingLimitSeconds)) seconds"
        }
        let minutes = Int(freeRecordingLimitSeconds / 60)
        return "\(minutes) minutes"
    }

    private func addSettingsRow(
        to stack: UIStackView,
        key: String,
        title: String,
        detail: String,
        isOn: Bool,
        compact: Bool = false,
        enabled: Bool = true
    ) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = compact ? 8 : 16
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = compact ? 0 : 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: compact ? 14 : 16, weight: .medium)
        titleLabel.textColor = enabled ? .white : UIColor.white.withAlphaComponent(0.34)
        enableSettingsTextWrapping(titleLabel)
        if compact {
            titleLabel.numberOfLines = 1
            titleLabel.adjustsFontSizeToFitWidth = true
            titleLabel.minimumScaleFactor = 0.9
        }

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = UIFont.systemFont(ofSize: 13)
        detailLabel.textColor = UIColor.white.withAlphaComponent(enabled ? 0.56 : 0.28)
        detailLabel.isHidden = detail.isEmpty
        enableSettingsTextWrapping(detailLabel)

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        let sensorSwitch = makeSettingsSwitch(key: key, isOn: isOn, enabled: enabled)
        row.addArrangedSubview(textStack)
        if compact {
            let switchContainer = UIView()
            switchContainer.widthAnchor.constraint(equalToConstant: 40).isActive = true
            switchContainer.heightAnchor.constraint(equalToConstant: 44).isActive = true
            sensorSwitch.translatesAutoresizingMaskIntoConstraints = false
            sensorSwitch.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
            switchContainer.addSubview(sensorSwitch)
            NSLayoutConstraint.activate([
                sensorSwitch.centerXAnchor.constraint(equalTo: switchContainer.centerXAnchor),
                sensorSwitch.centerYAnchor.constraint(equalTo: switchContainer.centerYAnchor)
            ])
            row.spacing = 6
            row.addArrangedSubview(switchContainer)
        } else { row.addArrangedSubview(sensorSwitch) }
        stack.addArrangedSubview(row)
    }

    private func makeSettingsSwitch(key: String, isOn: Bool, enabled: Bool) -> UISwitch {
        let sensorSwitch = UISwitch()
        sensorSwitch.isOn = isOn
        sensorSwitch.isEnabled = enabled
        sensorSwitch.onTintColor = .systemTeal
        sensorSwitch.accessibilityIdentifier = key
        sensorSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        if key.hasSuffix(".autoFocus") {
            sensorSwitch.addTarget(self, action: #selector(autoFocusSwitchChanged(_:)), for: .valueChanged)
        } else if key.hasSuffix(".autoExposure") {
            sensorSwitch.addTarget(self, action: #selector(autoExposureSwitchChanged(_:)), for: .valueChanged)
        } else if key == "audio" {
            sensorSwitch.addTarget(self, action: #selector(captureSensorChanged(_:)), for: .valueChanged)
        } else if key == "lidarDepth" {
            sensorSwitch.addTarget(self, action: #selector(depthEnabledSwitchChanged(_:)), for: .valueChanged)
        }
        settingsSwitches[key] = sensorSwitch

        return sensorSwitch
    }

    private func addDepthSettingsCard(to stack: UIStackView, enabled: Bool, available: Bool) {
        let card = addSettingsCard(to: stack, title: "LiDAR Depth", icon: "viewfinder.circle", identifier: "lidar")
        let toggle = makeSettingsSwitch(key: "lidarDepth", isOn: enabled && available, enabled: available)
        toggle.accessibilityLabel = "LiDAR Depth"
        (card.arrangedSubviews.first as? UIStackView)?.addArrangedSubview(toggle)
        if !available { addSettingsFootnote(to: card, text: "No LiDAR sensor on this device.") }
    }

    @objc private func depthEnabledSwitchChanged(_ sender: UISwitch) {
        guard settingsMenuButtons["captureMode"]?.accessibilityValue != "ARKit" else { return }
        rebuildCameraSettings(settingsDraft())
    }

    @objc private func captureSensorChanged(_ sender: UISwitch) {
        guard sender.isOn else { updateCameraResolutionMenus(); return }
        requestAudioAccess { granted in
            DispatchQueue.main.async {
                if !granted { sender.isOn = false }
                self.updateCameraResolutionMenus()
            }
        }
    }

    @objc private func autoFocusSwitchChanged(_ sender: UISwitch) {
        guard let switchKey = sender.accessibilityIdentifier,
              let keyPrefix = switchKey.split(separator: ".").first.map(String.init) else {
            return
        }
        let cameraEnabled = settingsSwitches["\(keyPrefix).enabled"]?.isOn ?? true
        updateFixedFocusControlState(keyPrefix: keyPrefix, cameraEnabled: cameraEnabled)
        if keyPrefix != "arkit" { updateCameraResolutionMenus() }
    }

    @objc private func autoExposureSwitchChanged(_ sender: UISwitch) {
        guard let switchKey = sender.accessibilityIdentifier,
              let keyPrefix = switchKey.split(separator: ".").first.map(String.init) else {
            return
        }
        let cameraEnabled = settingsSwitches["\(keyPrefix).enabled"]?.isOn ?? true
        updateAutoExposureControlState(keyPrefix: keyPrefix, cameraEnabled: cameraEnabled)
        if keyPrefix != "arkit" { updateCameraResolutionMenus() }
    }

    @objc private func upgradeButtonTapped() {
        purchasePremium()
    }

    @objc private func restorePurchaseButtonTapped() {
        restorePurchases()
    }

    private func addSettingsActionButtons(to stack: UIStackView) {
        let saveButton = UIButton(type: .system)
        settingsSaveButton = saveButton
        saveButton.accessibilityIdentifier = "settings.save"
        var config = UIButton.Configuration.filled()
        config.title = "Save Settings"
        config.baseBackgroundColor = .systemTeal
        config.baseForegroundColor = .black
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        saveButton.configuration = config
        saveButton.addTarget(self, action: #selector(saveSettingsOverlay), for: .touchUpInside)
        stack.addArrangedSubview(saveButton)
    }

    @objc private func saveSettingsOverlay() {
        let captureMode: CaptureMode = {
            let modeValue = settingsMenuButtons["captureMode"]?.accessibilityValue ?? "Standard"
            return modeValue == "ARKit" ? .arkit : .standard
        }()

        let arkitCameraSettings = CameraCaptureSettings(
            enabled: true,
            resolution: selectedSettingsValue(for: "arkit.resolution", fallback: recorderSettings.arkitCamera.resolution),
            frameRate: selectedSettingsValue(for: "arkit.frameRate", fallback: recorderSettings.arkitCamera.frameRate),
            autoFocus: settingsSwitches["arkit.autoFocus"]?.isOn ?? recorderSettings.arkitCamera.autoFocus,
            autoExposure: settingsSwitches["arkit.autoExposure"]?.isOn ?? isAutoExposureEnabled(for: recorderSettings.arkitCamera),
            maxExposureDurationMS: selectedSettingsValue(
                for: "arkit.maxExposure",
                fallback: maxExposureDurationLabel(for: recorderSettings.arkitCamera)
            ),
            fixedFocusLensPosition: selectedSliderValue(
                for: "arkit.fixedFocus",
                fallback: clampedLensPosition(
                    recorderSettings.arkitCamera.fixedFocusLensPosition,
                    fallback: defaultARKitFixedFocusLensPosition
                )
            )
        )

        let draft = settingsDraft()
        var updatedSettings = draft
        updatedSettings.captureMode = captureMode
        updatedSettings.arkitCamera = arkitCameraSettings
        updatedSettings.imuEnabled = settingsSwitches["imu"]?.isOn ?? draft.imuEnabled
        updatedSettings.magnetometerEnabled = settingsSwitches["mag"]?.isOn ?? draft.magnetometerEnabled
        updatedSettings.barometerEnabled = settingsSwitches["baro"]?.isOn ?? draft.barometerEnabled
        updatedSettings.geoLocationEnabled = settingsSwitches["geo"]?.isOn ?? draft.geoLocationEnabled
        updatedSettings.deviceMotionEnabled = settingsSwitches["motion"]?.isOn ?? draft.deviceMotionEnabled
        if captureMode == .arkit && !CaptureRateOptions.isWithinProductLimit(Double(arkitCameraSettings.frameRate) ?? .nan) {
            showError(msg: "This version supports up to 60 fps. Select a supported frame rate in Settings.")
            return
        }
        if updatedSettings.captureMode == .standard, let issue = standardConfigurationIssue(updatedSettings) {
            showError(msg: issue)
            return
        }
        if updatedSettings.captureMode == .standard {
            let previous = recorderSettings
            settingsOverlayView?.isUserInteractionEnabled = false
            recorderSettings = updatedSettings
            resetPreviewSessionForSettingsChange { issue in
                if let issue {
                    self.recorderSettings = previous
                    self.resetPreviewSessionForSettingsChange { restoreIssue in
                        self.settingsOverlayView?.isUserInteractionEnabled = true
                        let restoration = restoreIssue == nil ? "The previous configuration has been restored." : "Please choose a lighter configuration to restart preview."
                        self.showError(msg: "Settings were not saved. \(issue)\n\n\(restoration) No camera resolution or rate was automatically reduced.")
                    }
                } else {
                    self.recorderSettings.save()
                    self.settingsOverlayView?.isUserInteractionEnabled = true
                    self.setStatus("Settings saved")
                    self.hideSettingsOverlay()
                }
            }
            return
        }
        recorderSettings = updatedSettings
        sanitizeRecorderSettingsForCurrentDevice()
        recorderSettings.save()
        setStatus("Settings saved")
        hideSettingsOverlay()
        resetPreviewSessionForSettingsChange()
    }

    private func resetPreviewSessionForSettingsChange(completion: ((String?) -> Void)? = nil) {
        pendingPreviewCompletion = completion
        startStopButton.isEnabled = false
        sessionQueue.async {
            self.tearDownARKitSession()

            if self.observesSessionRuntimeErrors {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .AVCaptureSessionRuntimeError,
                    object: self.session
                )
                NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: self.session)
                self.observesSessionRuntimeErrors = false
            }
            self.session.stopRunning()
            self.standardSynchronizer?.setDelegate(nil, queue: nil)
            self.standardSynchronizer = nil
            self.multiCameraGraph?.close()
            self.multiCameraGraph = nil
            self.configuredCameraFormats.removeAll()
            self.captureCadence.removeAll()
            self.previewSampleSizes.removeAll()
            DispatchQueue.main.async { self.measuredCameraFPS.removeAll(); self.measuredCameraSizes.removeAll() }
            if completion == nil { self.sanitizeRecorderSettingsForCurrentDevice() }
            self.session = self.makeCaptureSession(for: self.recorderSettings)
            self.isConfigured = false
            self.wideVideoPort = nil
            self.ultraWideVideoPort = nil
            self.telephotoVideoPort = nil
            self.frontVideoPort = nil
            self.lidarDepthPort = nil
            self.wideDevice = nil
            self.ultraWideDevice = nil
            self.telephotoDevice = nil
            self.frontDevice = nil
            self.lidarDevice = nil
            self.widePreviewOutput = nil
            self.ultraWidePreviewOutput = nil
            self.telephotoPreviewOutput = nil
            self.frontPreviewOutput = nil
            self.lidarDepthOutput = nil
            self.audioOutput = nil
            self.wideFrameCount = 0
            self.ultraWideFrameCount = 0
            self.telephotoFrameCount = 0
            self.frontFrameCount = 0
            self.lidarDepthFrameCount = 0
            self.firstDepthSensorSec = nil
            self.latestDepthSensorSec = nil

            DispatchQueue.main.async {
                self.wideDisplayLayer?.removeFromSuperlayer()
                self.ultraWideDisplayLayer?.removeFromSuperlayer()
                self.telephotoDisplayLayer?.removeFromSuperlayer()
                self.frontDisplayLayer?.removeFromSuperlayer()
                self.depthPreviewView?.removeFromSuperview()
                self.wideDisplayLayer = nil
                self.ultraWideDisplayLayer = nil
                self.telephotoDisplayLayer = nil
                self.frontDisplayLayer = nil
                self.depthPreviewView = nil
                self.refreshOverlayStatus()
                self.preparePreviewSession()
            }
        }
    }

    private func selectedSettingsValue(for key: String, fallback: String) -> String {
        guard let value = settingsMenuButtons[key]?.accessibilityValue else {
            return fallback
        }
        return value
    }

    private func selectedSliderValue(for key: String, fallback: Double) -> Double {
        guard let value = settingsSliders[key]?.value else {
            return fallback
        }
        return clampedLensPosition(Double(value))
    }

    @objc private func hideSettingsOverlay() {
        settingsCapabilityGeneration = UUID()
        guard let controller = settingsController else { return }
        settingsRailButton?.isEnabled = false
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.settingsOverlayView?.removeFromSuperview()
            self.settingsOverlayView = nil
            self.settingsCameraContainer = nil
            self.settingsController = nil
            self.updateAuxiliaryRailButtons(isRecording: self.isRecording)
        }
    }

    private func initializeUI() {
        timeLabel.text = "Initializing"
        trackingStatusLabel.text = "wide"
        mappingStatusLabel.text = "ultrawide"
        frameCounterLabel.text = "Waiting for camera"
        fileSizeLabel.text = String(format: "? / %@", diskCapacity)
        fpsLabel.text = "30.0 FPS"
        fpsStepper.value = 30
        fpsStepper.isEnabled = false
        timeWriteLabel.text = "mp4,csv"
        updateRecordButtonAppearance(isRecording: false)
        refreshOverlayStatus()
    }

    @objc private func updateTime() {
        let elapsedSeconds = Date().timeIntervalSince(startTime)
        if shouldStopAtFreeRecordingLimit(elapsedSeconds: elapsedSeconds) {
            handleFreeRecordingLimitReached()
            return
        }
        updateFreeCountdown(elapsedSeconds: elapsedSeconds)

        var elapsed = Int64(round(elapsedSeconds))
        let hours: Int64 = elapsed / 3600
        elapsed = elapsed % 3600
        let mins: Int64 = elapsed / 60
        let secs: Int64 = elapsed % 60
        timeLabel.text = String(format: "%02d:%02d:%02d", hours, mins, secs)
        if isRecording {
            timeWriteLabel.text = recordingDataStatusText()
        }
        updateSize()
        refreshOverlayStatus()
    }

    private func shouldStopAtFreeRecordingLimit(elapsedSeconds: TimeInterval) -> Bool {
        isRecording &&
            !PurchaseManager.shared.isPremiumUnlocked &&
            !freeRecordingLimitStopRequested &&
            elapsedSeconds >= freeRecordingLimitSeconds
    }

    private func handleFreeRecordingLimitReached() {
        freeRecordingLimitStopRequested = true
        hideFreeCountdown()
        timeLabel.text = "Limit reached"
        stopRecording(showUpgradePromptAfterFinish: true)
    }

    private func updateFreeCountdown(elapsedSeconds: TimeInterval) {
        guard isRecording, !PurchaseManager.shared.isPremiumUnlocked else {
            hideFreeCountdown()
            return
        }

        let secondsLeft = max(Int(ceil(freeRecordingLimitSeconds - elapsedSeconds)), 0)
        guard secondsLeft <= Int(freeCountdownVisibleThresholdSeconds), secondsLeft > 0 else {
            hideFreeCountdown()
            return
        }

        freeCountdownLabel?.text = "Free session time left: \(secondsLeft)s"
        freeCountdownLabel?.isHidden = false
    }

    private func hideFreeCountdown() {
        freeCountdownLabel?.isHidden = true
    }

    private func refreshOverlayStatus() {
        if isARKitMode {
            let res = arkitActiveResolution()
            let hz = arkitFrameCount == 0 ? "0 Hz" : String(format: "%.0f Hz", targetRecordingFrameRate(for: recorderSettings.arkitCamera))
            let trackingLabel = shortTrackingStateLabel(arkitTrackingState)
            let recTag = isRecording ? "REC" : "preview"
            cameraStatusRows["wide"]?.text = "ARKit \(Int(res.width))x\(Int(res.height)) | \(hz) | \(recTag) | \(trackingLabel)"
            updateCameraStatusColor(key: "wide", enabled: true, activeRecorder: arkitRecorder != nil)
            cameraStatusRows["ultra"]?.text = "ARKit OFF"
            updateCameraStatusColor(key: "ultra", enabled: false, activeRecorder: false)
            cameraStatusRows["telephoto"]?.text = "ARKit OFF"
            updateCameraStatusColor(key: "telephoto", enabled: false, activeRecorder: false)
            cameraStatusRows["front"]?.text = "ARKit OFF"
            updateCameraStatusColor(key: "front", enabled: false, activeRecorder: false)
        } else {
            cameraStatusRows["wide"]?.text = cameraStatusText(
                frameCount: wideFrameCount,
                device: wideDevice,
                fallbackName: "wide.mp4",
                settings: recorderSettings.wide
            )
            updateCameraStatusColor(key: "wide", enabled: recorderSettings.wide.enabled, activeRecorder: wideRecorder != nil)
            cameraStatusRows["ultra"]?.text = cameraStatusText(
                frameCount: ultraWideFrameCount,
                device: ultraWideDevice,
                fallbackName: "ultrawide.mp4",
                settings: recorderSettings.ultraWide
            )
            updateCameraStatusColor(key: "ultra", enabled: recorderSettings.ultraWide.enabled, activeRecorder: ultraWideRecorder != nil)
            cameraStatusRows["telephoto"]?.text = cameraStatusText(
                frameCount: telephotoFrameCount,
                device: telephotoDevice,
                fallbackName: "telephoto.mp4",
                settings: recorderSettings.telephoto
            )
            updateCameraStatusColor(key: "telephoto", enabled: recorderSettings.telephoto.enabled, activeRecorder: telephotoRecorder != nil)
            cameraStatusRows["front"]?.text = cameraStatusText(
                frameCount: frontFrameCount,
                device: frontDevice,
                fallbackName: "front.mp4",
                settings: recorderSettings.front
            )
            updateCameraStatusColor(key: "front", enabled: recorderSettings.front.enabled, activeRecorder: frontRecorder != nil)
        }
        cameraStatusRows["depth"]?.text = depthStatusText()
        updateCameraStatusColor(key: "depth", enabled: recorderSettings.lidarDepthEnabled, activeRecorder: lidarDepthRecorder != nil)

        let sensorRows = sensorRecorder?.statusRows() ?? [:]
        updateSensorPill(key: "imu", title: "IMU", value: sensorRows["imu"] ?? "0Hz")
        updateSensorPill(key: "mag", title: "Mag", value: sensorRows["mag"] ?? "0Hz")
        updateSensorPill(key: "baro", title: "Baro", value: sensorRows["baro"] ?? "0Hz")
        updateSensorPill(key: "geo", title: "GeoLoc", value: locationRecorder?.statusValue() ?? "0Hz")
        updateSensorPill(key: "motion", title: "Motion", value: sensorRows["motion"] ?? "0Hz")
        updateSensorPill(key: "audio", title: "Audio", value: audioRecorder?.statusValue() ?? "0Hz")
        updateSensorPill(key: "depth", title: "Depth", value: depthStatusValue())

        captureStatusRows["duration"]?.text = isRecording ? (timeLabel.text ?? "00:00:00") : "00:00:00"
        captureStatusRows["size"]?.text = fileSizeLabel.text ?? "? / ?"
        captureStatusRows["mode"]?.text = isRecording ? "Recording" : "Preview"
        captureStatusRows["write"]?.text = isRecording ? recordingDataStatusText() : "mp4 + csv + m4a"
        updateModeBadge()
        updateCaptureSummaryLabel()
    }

    private func shortTrackingStateLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable: return "N/A"
        case .limited: return "Limited"
        case .normal: return "Normal"
        }
    }

    private func updateModeBadge() {
        guard let label = modeBadgeLabel, let badge = modeBadge else { return }
        if isARKitMode {
            let tracking = arkitTrackingState
            let trackingText: String
            let trackingColor: UIColor
            switch tracking {
            case .normal:
                trackingText = "Normal"
                trackingColor = .systemGreen
            case .limited:
                trackingText = "Limited"
                trackingColor = .systemYellow
            case .notAvailable:
                trackingText = "Not Available"
                trackingColor = UIColor.white.withAlphaComponent(0.45)
            }
            let modeText = "ARKit"
            let separator = "  |  "
            let fullText = "\(modeText)\(separator)\(trackingText)"
            let attr = NSMutableAttributedString(string: fullText)
            attr.addAttribute(.foregroundColor, value: UIColor.systemTeal, range: NSRange(location: 0, length: modeText.count))
            attr.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.35), range: NSRange(location: modeText.count, length: separator.count))
            attr.addAttribute(.foregroundColor, value: trackingColor, range: NSRange(location: modeText.count + separator.count, length: trackingText.count))
            label.attributedText = attr
            badge.layer.borderColor = isRecording ? UIColor.systemTeal.withAlphaComponent(0.5).cgColor : UIColor.white.withAlphaComponent(0.15).cgColor
        } else {
            label.attributedText = nil
            label.text = "Standard"
            label.textColor = UIColor.white.withAlphaComponent(0.6)
            badge.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    private func cameraStatusText(frameCount: Int, device: AVCaptureDevice?, fallbackName: String, settings: CameraCaptureSettings) -> String {
        let camera: RecordingCamera = fallbackName.hasPrefix("wide") ? .wide : fallbackName.hasPrefix("telephoto") ? .telephoto : fallbackName.hasPrefix("front") ? .front : .ultraWide
        let resolution: String
        if let measured = measuredCameraSizes[camera] { resolution = measured }
        else if let graph = multiCameraGraph { resolution = graph.request.resolution }
        else if let device = device {
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            resolution = "\(dimensions.width)x\(dimensions.height)"
        } else {
            resolution = settings.resolution
        }

        let cameraName: String
        if fallbackName.hasPrefix("wide") {
            cameraName = "WIDE"
        } else if fallbackName.hasPrefix("telephoto") {
            cameraName = "TELE"
        } else if fallbackName.hasPrefix("front") {
            cameraName = "FRONT"
        } else {
            cameraName = "ULTRAWIDE"
        }
        let hz = String(format: "%.1f Hz", measuredCameraFPS[camera] ?? 0)
        return "\(cameraName) \(aspectLabel(for: resolution)) | \(resolution) | \(hz)"
    }

    private func depthStatusText() -> String {
        guard recorderSettings.lidarDepthEnabled else {
            return "DEPTH OFF"
        }
        if isARKitMode {
            let resolution = recorderSettings.arkitCamera.resolution
            return "DEPTH \(resolution) | \(depthStatusValue())"
        }
        guard let output = lidarDepthOutput else {
            return "DEPTH --"
        }
        let dimensions = output.connections.first?.inputPorts.first?.formatDescription
            .map(CMVideoFormatDescriptionGetDimensions)
        let resolution = dimensions.map { "\($0.width)x\($0.height)" } ?? "--"
        return "DEPTH \(resolution) | \(depthStatusValue())"
    }

    private func depthStatusValue() -> String {
        guard lidarDepthFrameCount > 0 else { return "0Hz" }
        guard let firstDepthSensorSec,
              let latestDepthSensorSec,
              latestDepthSensorSec > firstDepthSensorSec else {
            return "Depth"
        }
        let hz = Double(max(lidarDepthFrameCount - 1, 1)) / (latestDepthSensorSec - firstDepthSensorSec)
        return String(format: "%.0fHz", hz)
    }

    private func aspectLabel(for resolution: String) -> String {
        guard let size = resolutionSize(from: resolution), size.height > 0 else {
            return "--"
        }
        let ratio = size.width / size.height
        if abs(ratio - (4.0 / 3.0)) < 0.03 {
            return "4:3"
        }
        if abs(ratio - (16.0 / 9.0)) < 0.03 {
            return "16:9"
        }
        return String(format: "%.2f:1", ratio)
    }

    private func videoCodecName(for settings: CameraCaptureSettings) -> String {
        guard let size = resolutionSize(from: settings.resolution) else {
            return "h264"
        }
        return CameraStreamRecorder.preferredVideoCodec(width: Int(size.width), height: Int(size.height)) == .hevc ? "hevc" : "h264"
    }

    private func updateCameraStatusColor(key: String, enabled: Bool, activeRecorder: Bool) {
        guard let label = cameraStatusRows[key] else { return }
        label.textColor = isRecording && enabled && activeRecorder ? .systemGreen : UIColor.white.withAlphaComponent(0.42)
    }

    private func updateSensorPill(key: String, title: String, value: String) {
        guard let label = sensorStatusRows[key] else { return }
        let active = isRecording && !value.hasPrefix("0Hz") && value != "--"
        label.text = "\(title) \(value)"
        label.textColor = active ? UIColor.systemGreen : UIColor.white.withAlphaComponent(0.42)
    }

    private func captureSummaryText() -> String {
        guard isRecording else { return "" }
        let time = elapsedRecordingTimeText()
        let captureBytes = currentCaptureBytes()
        let captureSize = megabyteText(captureBytes)
        let freeBytes = availableDiskBytes()
        let freeSize = freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? diskCapacity
        let remaining = estimatedRemainingRecordTime(captureBytes: captureBytes, freeBytes: freeBytes)
        return "REC \(time) / \(captureSize) | FREE \(freeSize) | REM \(remaining)"
    }

    private func updateCaptureSummaryLabel() {
        guard let label = captureStatusRows["summary"] else { return }
        guard isRecording else {
            label.attributedText = nil
            label.text = ""
            return
        }

        let text = captureSummaryText()
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: UIColor.systemRed.withAlphaComponent(0.92)
            ]
        )
        attributed.addAttribute(
            .foregroundColor,
            value: UIColor.systemRed.withAlphaComponent(recBlinkVisible ? 1.0 : 0.18),
            range: NSRange(location: 0, length: min(3, text.count))
        )
        label.attributedText = attributed
    }

    private func elapsedRecordingTimeText() -> String {
        guard let startTime else { return "00:00:00" }
        return durationText(seconds: max(Date().timeIntervalSince(startTime), 0))
    }

    private func megabyteText(_ bytes: Int64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_000_000.0)
    }

    private func currentCaptureBytes() -> Int64 {
        guard let outDirURL = outDirURL,
              let size = try? outDirURL.directoryTotalAllocatedSize(includingSubfolders: true) else {
            return 0
        }
        return Int64(size)
    }

    private func availableDiskBytes() -> Int64? {
        guard let values = try? getRecDir().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return bytes
    }

    private func estimatedRemainingRecordTime(captureBytes: Int64, freeBytes: Int64?) -> String {
        guard isRecording,
              let freeBytes = freeBytes,
              captureBytes > 0 else {
            return "00:00:00"
        }
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 3 else { return "00:00:00" }
        let bytesPerSecond = Double(captureBytes) / elapsed
        guard bytesPerSecond > 1 else { return "00:00:00" }
        return durationText(seconds: TimeInterval(Double(freeBytes) / bytesPerSecond))
    }

    private func durationText(seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func recordingDataStatusText() -> String {
        let sensorStatus = sensorRecorder?.statusText() ?? "sensors starting"
        let locationStatus = locationRecorder?.statusText() ?? "L --"
        let audioStatus = audioRecorder?.statusText() ?? "AUD --"
        let depthStatus = lidarDepthRecorder == nil ? "D --" : "D raw"
        return "\(sensorStatus) \(locationStatus) \(audioStatus) \(depthStatus)"
    }

    private func updateSize() {
        var str: String = "?"
        if let size = try? outDirURL?.sizeOnDisk() {
            str = size
        }
        fileSizeLabel.text = String(format: "%@ / %@", str, diskCapacity)
    }

    private func showError(msg: String) {
        DispatchQueue.main.async {
            if self.recordingTransition == .preparing {
                self.recordingTransition = .none
            }
            let presenter: UIViewController = self.settingsController ?? self
            guard presenter.presentedViewController == nil else { return }
            let fileAlert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            fileAlert.view.accessibilityIdentifier = "capture.error"
            fileAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            presenter.present(fileAlert, animated: true, completion: nil)
        }
    }

    private func showMessage(title: String, message: String) {
        DispatchQueue.main.async {
            let presenter: UIViewController = self.settingsController ?? self
            guard presenter.presentedViewController == nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            presenter.present(alert, animated: true, completion: nil)
        }
    }

    private func showFreeRecordingLimitAlert() {
        DispatchQueue.main.async {
            guard self.presentedViewController == nil else { return }
            let alert = UIAlertController(
                title: "Free Recording Limit Reached",
                message: "Free users can record up to \(self.freeRecordingLimitMinutesText()) per session. Upgrade once to unlock unlimited recording length.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Upgrade", style: .default) { _ in
                self.purchasePremium()
            })
            alert.addAction(UIAlertAction(title: "Restore Purchase", style: .default) { _ in
                self.restorePurchases()
            })
            alert.addAction(UIAlertAction(title: "Later", style: .cancel, handler: nil))
            self.present(alert, animated: true, completion: nil)
        }
    }

    private func purchasePremium() {
        setStatus("Loading upgrade")
        Task {
            do {
                let outcome = try await PurchaseManager.shared.purchasePremium()
                await MainActor.run {
                    switch outcome {
                    case .purchased:
                        self.setStatus("Premium unlocked")
                        self.hideFreeCountdown()
                        self.refreshSettingsOverlayIfVisible()
                        self.showMessage(
                            title: "Premium Unlocked",
                            message: "Unlimited recording length is now enabled."
                        )
                    case .pending:
                        self.setStatus("Purchase pending")
                        self.showMessage(
                            title: "Purchase Pending",
                            message: "The App Store is still processing this purchase. Unlimited recording will unlock after approval."
                        )
                    case .cancelled:
                        self.setStatus("Upgrade cancelled")
                    }
                }
            } catch {
                await MainActor.run {
                    self.setStatus("Upgrade unavailable")
                    self.showError(msg: error.localizedDescription)
                }
            }
        }
    }

    private func restorePurchases() {
        setStatus("Restoring")
        Task {
            do {
                let restored = try await PurchaseManager.shared.restorePurchases()
                await MainActor.run {
                    if restored {
                        self.setStatus("Premium restored")
                        self.hideFreeCountdown()
                        self.refreshSettingsOverlayIfVisible()
                        self.showMessage(
                            title: "Purchase Restored",
                            message: "Unlimited recording length is now enabled."
                        )
                    } else {
                        self.setStatus("No purchase found")
                        self.showMessage(
                            title: "No Purchase Found",
                            message: "No previous unlimited recording purchase was found for this Apple ID."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.setStatus("Restore failed")
                    self.showError(msg: error.localizedDescription)
                }
            }
        }
    }

    private func refreshSettingsOverlayIfVisible() {
        guard settingsOverlayView != nil else { return }
        settingsPurchaseStatusLabel?.text = purchaseStatusText()
    }

    private func showPermissionSettingsAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let presenter: UIViewController = self.settingsController ?? self
            guard presenter.presentedViewController == nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            })
            presenter.present(alert, animated: true, completion: nil)
        }
    }

    private func createFiles() -> Bool {
        let recDirURL = getRecDir()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let date = dateFormatter.string(from: Date())
        outDirURL = recDirURL.appendingPathComponent("SR_\(date)")
        if FileManager.default.fileExists(atPath: outDirURL.path) {
            outDirURL = recDirURL.appendingPathComponent("SR_\(date)_\(UUID().uuidString.prefix(8))")
        }
        do {
            try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            os_log("Cannot create the output directory: %@", type: .error, error.localizedDescription)
            return false
        }

        writeCaptureMetaJSON(state: "created")
        updateDiskCapacity()
        return true
    }

    private func currentRecordingSettingsJSON() -> [String: Any] {
        return [
            "capture_mode": recorderSettings.captureMode.rawValue,
            "wide": cameraSettingsJSON(
                recorderSettings.wide,
                defaultLensPosition: defaultWideFixedFocusLensPosition
            ),
            "ultrawide": cameraSettingsJSON(
                recorderSettings.ultraWide,
                defaultLensPosition: defaultUltraWideFixedFocusLensPosition
            ),
            "telephoto": cameraSettingsJSON(
                recorderSettings.telephoto,
                defaultLensPosition: defaultTelephotoFixedFocusLensPosition
            ),
            "front": cameraSettingsJSON(
                recorderSettings.front,
                defaultLensPosition: defaultFrontFixedFocusLensPosition
            ),
            "arkit_camera": cameraSettingsJSON(
                recorderSettings.arkitCamera,
                defaultLensPosition: defaultARKitFixedFocusLensPosition
            ),
            "imu_enabled": recorderSettings.imuEnabled,
            "magnetometer_enabled": recorderSettings.magnetometerEnabled,
            "barometer_enabled": recorderSettings.barometerEnabled,
            "geo_location_enabled": recorderSettings.geoLocationEnabled,
            "device_motion_enabled": recorderSettings.deviceMotionEnabled,
            "audio_enabled": recorderSettings.audioEnabled,
            "lidar_depth_enabled": recorderSettings.lidarDepthEnabled,
            "depth_resolution": "automatic",
            "depth_frame_rate_limit": "10",
            "premium_unlocked": PurchaseManager.shared.isPremiumUnlocked,
            "free_recording_limit_sec": freeRecordingLimitSeconds
        ]
    }

    private func cameraSettingsJSON(
        _ settings: CameraCaptureSettings,
        defaultLensPosition: Double
    ) -> [String: Any] {
        return [
            "enabled": settings.enabled,
            "resolution": settings.resolution,
            "target_frame_rate": targetRecordingFrameRate(for: settings),
            "auto_focus": settings.autoFocus,
            "auto_exposure": isAutoExposureEnabled(for: settings),
            "fixed_focus_lens_position_requested": clampedLensPosition(
                settings.fixedFocusLensPosition,
                fallback: defaultLensPosition
            ),
            "max_exposure_duration_sec": maxExposureDurationSeconds(for: settings)
        ]
    }

    private func recordingStartJSON() -> [String: Any] {
        let hardware = multiCameraGraph?.hardwareSyncCameras ?? []
        let mixed = recorderSettings.front.enabled && enabledCameraCount(in: recorderSettings) > 1
        var result: [String: Any] = [
            "sampling_rule": recorderSettings.captureMode == .standard
                ? (mixed ? "After initial stream warm-up establishes the common movie epoch, all original frames are retained. Rear hardware groups, when present, are synchronized separately; front records independently with a nearest-timestamp correspondence index." : enabledCameraCount(in: recorderSettings) > 1
                    ? "Virtual-camera hardware-synchronized constituent ports in AVCaptureMultiCamSession; AVCaptureDataOutputSynchronizer delivers complete groups, original PTS and common movie epoch; record_slot is the shared hardware-sync group index."
                    : "Single camera records original capture timestamps; record_slot is the received-frame sequence.")
                : "ARKit MP4/info rows are downsampled onto a host-time record_slot grid at target_fps.",
            "lidar_depth_enabled": recorderSettings.lidarDepthEnabled,
            "synchronized_group_count": synchronizationGroup,
            "synchronized_dropped_groups": synchronizationDroppedGroups,
            "synchronized_max_skew_sec": synchronizationMaxSkew,
            "synchronization_scope": recorderSettings.captureMode == .arkit ? "ARKit single camera" :
                synchronizationDescription(recorderSettings),
            "hardware_synchronized_cameras": hardware.map(\.rawValue).sorted(),
            "all_cameras_hardware_synchronized": multiCameraGraph?.isFullyHardwareSynchronized ?? false
        ]
        if let graph = multiCameraGraph, graph.hardwareSyncCameras.count > 1 {
            result["hardware_sync"] = [
                "virtual_device_id": graph.device.uniqueID,
                "virtual_device_type": graph.device.deviceType.rawValue,
                "virtual_format": formatResolution(graph.format),
                "format_is_binned": graph.format.isVideoBinned,
                "hardware_cost": graph.session.hardwareCost,
                "system_pressure_cost": graph.session.systemPressureCost,
                "focus_mode": graph.device.focusMode.rawValue,
                "white_balance_mode": graph.device.whiteBalanceMode.rawValue,
                "exposure_mode": graph.device.exposureMode.rawValue,
                "max_exposure_sec": CMTimeGetSeconds(graph.device.activeMaxExposureDuration),
                "ports": graph.ports.filter { graph.hardwareSyncCameras.contains($0.key) }.map { camera, port in ["camera": camera.rawValue, "source_type": port.sourceDeviceType?.rawValue ?? "unknown"] }
            ] as [String: Any]
        }
        if let origin = synchronizationOrigin {
            result["shared_movie_origin_capture_pts_sec"] = CMTimeGetSeconds(origin)
            result["shared_movie_origin_sensor_sec"] = synchronizationOriginSensorSec
        }
        if let alignment = timestampAlignmentSummary, recorderSettings.captureMode == .standard {
            result["timestamp_alignment"] = ["index_file": "timestamp_alignment.csv", "reference_camera": alignment.reference,
                "rows": alignment.rows, "maximum_skew_sec": alignment.maximumSkew,
                "method": "nearest existing frame by original sensor_sec; no media resampling or frame removal"] as [String: Any]
        }
        if let recordingFailure { result["failure"] = recordingFailure }
        if recorderSettings.captureMode == .arkit {
            result["arkit_target_fps"] = targetRecordingFrameRate(for: recorderSettings.arkitCamera)
            result["arkit_capture_fps"] = arkitActiveFrameRate()
        } else {
            result["movie_media_time_scale"] = CameraStreamRecorder.videoMediaTimeScale
            result["wide_target_fps"] = targetRecordingFrameRate(for: recorderSettings.wide)
            result["wide_capture_fps"] = activeFrameRate(for: wideDevice, settings: recorderSettings.wide)
            result["ultrawide_target_fps"] = targetRecordingFrameRate(for: recorderSettings.ultraWide)
            result["ultrawide_capture_fps"] = activeFrameRate(for: ultraWideDevice, settings: recorderSettings.ultraWide)
            result["telephoto_target_fps"] = targetRecordingFrameRate(for: recorderSettings.telephoto)
            result["telephoto_capture_fps"] = activeFrameRate(for: telephotoDevice, settings: recorderSettings.telephoto)
            result["front_target_fps"] = targetRecordingFrameRate(for: recorderSettings.front)
            result["front_capture_fps"] = activeFrameRate(for: frontDevice, settings: recorderSettings.front)
        }
        return result
    }

    private func coordinateConventionsJSON() -> [String: String] {
        if recorderSettings.captureMode == .arkit {
            return [
                "arkit_world": "right-handed gravity-aligned world; y is up",
                "recorded_camera": "OpenCV/Rerun RDF: x right, y down, z forward",
                "pose": "T_world_camera (parent_from_child): p_world = R * p_camera + t",
                "pixel_coordinates": "origin top-left; x right, y down",
                "pixel_orientation": "ARKit native landscape pixels; device locked to Landscape Right",
                "quaternion_order": "qw,qx,qy,qz"
            ]
        }
        return [
            "recorded_camera": "AVFoundation camera intrinsics aligned to each encoded image; no per-frame world pose",
            "pixel_coordinates": "origin top-left; x right, y down",
            "pixel_orientation": "Landscape Right",
            "camera_extrinsics": "T_reference_from_camera when supplied; see camera_extrinsics"
        ]
    }

    private func cameraExtrinsicsJSON() -> [String: Any] {
        return [
            "reference": "wide_camera",
            "matrix_format": "3x4 row-major JSON array converted from Apple's column-major matrix_float4x3",
            "unit": "rotation unitless, translation in meters (converted from AVFoundation millimeters)",
            "T_wide_from_ultrawide": extrinsicJSON(from: ultraWideDevice, to: wideDevice),
            "T_wide_from_telephoto": extrinsicJSON(from: telephotoDevice, to: wideDevice),
            "T_wide_from_front": extrinsicJSON(from: frontDevice, to: wideDevice),
            "T_wide_from_lidar": extrinsicJSON(from: lidarDevice, to: wideDevice)
        ]
    }

    private func extrinsicJSON(from source: AVCaptureDevice?, to target: AVCaptureDevice?) -> Any {
        guard let source, let target else { return NSNull() }
        guard #available(iOS 17.0, *) else { return NSNull() }
        guard let data = AVCaptureDevice.extrinsicMatrix(from: source, to: target),
              data.count >= MemoryLayout<simd_float4x3>.size else {
            return NSNull()
        }
        let matrix = data.withUnsafeBytes { rawBuffer -> simd_float4x3 in
            rawBuffer.load(as: simd_float4x3.self)
        }
        return [
            [matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x, matrix.columns.3.x / 1000],
            [matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y, matrix.columns.3.y / 1000],
            [matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z, matrix.columns.3.z / 1000]
        ]
    }

    private func deviceMetadataJSON() -> [String: Any] {
        let device = UIDevice.current
        return [
            "device_id": device.identifierForVendor?.uuidString ?? "unknown",
            "device_id_source": "UIDevice.identifierForVendor; may change after reinstall or vendor changes",
            "name": device.name,
            "model": device.model,
            "localized_model": device.localizedModel,
            "model_identifier": modelIdentifier(),
            "system_name": device.systemName,
            "system_version": device.systemVersion
        ]
    }

    private func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(String(UnicodeScalar(UInt8(value))))
        }
    }

    private func writeCaptureMetaJSON(state: String) {
        let hostSec = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let utcSec = Date().timeIntervalSince1970
        let utcMinusSensorOffsetSec = utcSec - hostSec
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let metaURL = outDirURL.appendingPathComponent("meta.json")
        let meta: [String: Any] = [
            "format_version": 1,
            "state": state,
            "app": [
                "name": Bundle.main.bundleIdentifier ?? "SensorRecorder",
                "version": appVersion,
                "build": buildVersion
            ],
            "device": deviceMetadataJSON(),
            "created_utc_sec": utcSec,
            "updated_utc_sec": utcSec,
            "recording_settings": currentRecordingSettingsJSON(),
            "recording_start": recordingStartJSON(),
            "capture_mode": recorderSettings.captureMode.rawValue,
            "coordinate_conventions": coordinateConventionsJSON(),
            "camera_extrinsics": cameraExtrinsicsJSON(),
            "time_model": [
                "sensor_sec": "monotonic host clock seconds; same time base used by AVFoundation capture timestamps after conversion, CoreMotion timestamps, and derived geo_location timestamps",
                "capture_pts_sec": "Standard video original session synchronization-clock PTS, before host conversion; MP4 preserves this cadence relative to its common capture origin. sensor_sec is converted once on admission, since audio clock correlation can change.",
                "utc_sec": "Unix UTC seconds",
                "utc_minus_sensor_offset_sec": utcMinusSensorOffsetSec,
                "alignment": "Use sensor_sec for sensor fusion. Use utc_sec for wall-clock/GNSS-style correlation."
            ],
            "streams": [
                "wide_camera": [
                    "enabled": recorderSettings.wide.enabled || recorderSettings.captureMode == .arkit,
                    "media_file": "wide.mp4",
                    "index_file": recorderSettings.captureMode == .arkit ? "arkit_pose.csv" : "wide_info.csv",
                    "source": recorderSettings.captureMode == .arkit ? "ARKit" : String(describing: type(of: session)),
                    "codec": recorderSettings.captureMode == .arkit
                        ? (arkitRecorder?.codecName ?? "h264")
                        : videoCodecName(for: recorderSettings.wide),
                    "target_fps": recorderSettings.captureMode == .arkit
                        ? targetRecordingFrameRate(for: recorderSettings.arkitCamera)
                        : targetRecordingFrameRate(for: recorderSettings.wide),
                    "capture_fps": recorderSettings.captureMode == .arkit
                        ? arkitActiveFrameRate()
                        : activeFrameRate(for: wideDevice, settings: recorderSettings.wide),
                    "requested_resolution": recorderSettings.captureMode == .arkit
                        ? recorderSettings.arkitCamera.resolution
                        : recorderSettings.wide.resolution,
                    "auto_focus": recorderSettings.captureMode == .arkit
                        ? recorderSettings.arkitCamera.autoFocus
                        : recorderSettings.wide.autoFocus,
                    "auto_exposure": recorderSettings.captureMode == .arkit
                        ? isAutoExposureEnabled(for: recorderSettings.arkitCamera)
                        : isAutoExposureEnabled(for: recorderSettings.wide),
                    "fixed_focus_lens_position_requested": recorderSettings.captureMode == .arkit
                        ? clampedLensPosition(
                            recorderSettings.arkitCamera.fixedFocusLensPosition,
                            fallback: defaultARKitFixedFocusLensPosition
                        )
                        : clampedLensPosition(
                            recorderSettings.wide.fixedFocusLensPosition,
                            fallback: defaultWideFixedFocusLensPosition
                        ),
                    "max_exposure_duration_sec": recorderSettings.captureMode == .arkit
                        ? maxExposureDurationSeconds(for: recorderSettings.arkitCamera)
                        : maxExposureDurationSeconds(for: recorderSettings.wide),
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": recorderSettings.captureMode == .arkit
                        ? ["frame_index", "record_slot", "sensor_sec", "utc_sec", "tx_m", "ty_m", "tz_m", "qw", "qx", "qy", "qz", "exposure_sec", "tracking_state", "fx_px", "fy_px", "cx_px", "cy_px", "width_px", "height_px"]
                        : ["frame_index", "record_slot", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"]
                ],
                "ultrawide_camera": [
                    "enabled": recorderSettings.ultraWide.enabled && recorderSettings.captureMode == .standard,
                    "media_file": "ultrawide.mp4",
                    "index_file": "ultra_info.csv",
                    "codec": videoCodecName(for: recorderSettings.ultraWide),
                    "target_fps": targetRecordingFrameRate(for: recorderSettings.ultraWide),
                    "capture_fps": activeFrameRate(for: ultraWideDevice, settings: recorderSettings.ultraWide),
                    "requested_resolution": recorderSettings.ultraWide.resolution,
                    "auto_focus": recorderSettings.ultraWide.autoFocus,
                    "auto_exposure": isAutoExposureEnabled(for: recorderSettings.ultraWide),
                    "fixed_focus_lens_position_requested": clampedLensPosition(
                        recorderSettings.ultraWide.fixedFocusLensPosition,
                        fallback: defaultUltraWideFixedFocusLensPosition
                    ),
                    "max_exposure_duration_sec": maxExposureDurationSeconds(for: recorderSettings.ultraWide),
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "record_slot", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"]
                ],
                "telephoto_camera": [
                    "enabled": recorderSettings.telephoto.enabled && recorderSettings.captureMode == .standard,
                    "media_file": "telephoto.mp4",
                    "index_file": "tele_info.csv",
                    "codec": videoCodecName(for: recorderSettings.telephoto),
                    "target_fps": targetRecordingFrameRate(for: recorderSettings.telephoto),
                    "capture_fps": activeFrameRate(for: telephotoDevice, settings: recorderSettings.telephoto),
                    "requested_resolution": recorderSettings.telephoto.resolution,
                    "auto_focus": recorderSettings.telephoto.autoFocus,
                    "auto_exposure": isAutoExposureEnabled(for: recorderSettings.telephoto),
                    "fixed_focus_lens_position_requested": clampedLensPosition(
                        recorderSettings.telephoto.fixedFocusLensPosition,
                        fallback: defaultTelephotoFixedFocusLensPosition
                    ),
                    "max_exposure_duration_sec": maxExposureDurationSeconds(for: recorderSettings.telephoto),
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "record_slot", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"]
                ],
                "front_camera": [
                    "enabled": recorderSettings.front.enabled && recorderSettings.captureMode == .standard,
                    "media_file": "front.mp4",
                    "index_file": "front_info.csv",
                    "codec": videoCodecName(for: recorderSettings.front),
                    "target_fps": targetRecordingFrameRate(for: recorderSettings.front),
                    "capture_fps": activeFrameRate(for: frontDevice, settings: recorderSettings.front),
                    "requested_resolution": recorderSettings.front.resolution,
                    "auto_focus": recorderSettings.front.autoFocus,
                    "auto_exposure": isAutoExposureEnabled(for: recorderSettings.front),
                    "fixed_focus_lens_position_requested": clampedLensPosition(
                        recorderSettings.front.fixedFocusLensPosition,
                        fallback: defaultFrontFixedFocusLensPosition
                    ),
                    "max_exposure_duration_sec": maxExposureDurationSeconds(for: recorderSettings.front),
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "record_slot", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"]
                ],
                "arkit_pose": [
                    "enabled": recorderSettings.captureMode == .arkit,
                    "media_file": "wide.mp4",
                    "index_file": "arkit_pose.csv",
                    "codec": arkitRecorder?.codecName ?? "h264",
                    "target_fps": targetRecordingFrameRate(for: recorderSettings.arkitCamera),
                    "capture_fps": arkitActiveFrameRate(),
                    "requested_resolution": recorderSettings.arkitCamera.resolution,
                    "auto_focus": recorderSettings.arkitCamera.autoFocus,
                    "auto_exposure": isAutoExposureEnabled(for: recorderSettings.arkitCamera),
                    "fixed_focus_lens_position_requested": clampedLensPosition(
                        recorderSettings.arkitCamera.fixedFocusLensPosition,
                        fallback: defaultARKitFixedFocusLensPosition
                    ),
                    "max_exposure_duration_sec": maxExposureDurationSeconds(for: recorderSettings.arkitCamera),
                    "world_alignment": "gravity",
                    "world_coordinates": "ARKit gravity-aligned right-handed world",
                    "camera_coordinates": "OpenCV/Rerun RDF (x right, y down, z forward)",
                    "pose_convention": "T_world_camera (parent_from_child)",
                    "pixel_orientation": "ARKit native landscape pixels; device locked to Landscape Right",
                    "source": "ARKit ARWorldTrackingConfiguration with builtInWideAngleCamera",
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": [
                        "frame_index",
                        "record_slot",
                        "sensor_sec",
                        "utc_sec",
                        "tx_m",
                        "ty_m",
                        "tz_m",
                        "qw",
                        "qx",
                        "qy",
                        "qz",
                        "exposure_sec",
                        "tracking_state",
                        "fx_px",
                        "fy_px",
                        "cx_px",
                        "cy_px",
                        "width_px",
                        "height_px"
                    ]
                ],
                "audio": [
                    "enabled": recorderSettings.audioEnabled,
                    "media_file": "audio.m4a",
                    "index_file": "audio_info.csv",
                    "embedded_in": embedAudioInCameraMP4 && recorderSettings.captureMode == .standard
                        ? ["wide.mp4", "ultrawide.mp4", "telephoto.mp4", "front.mp4"]
                        : [],
                    "codec": "aac",
                    "container": "m4a",
                    "requested_channels": 2,
                    "channel_count_source": "actual channel count is written per buffer in audio_info.csv",
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "duration_sec", "sample_count", "sample_rate_hz", "channels"]
                ],
                "lidar_depth": [
                    "enabled": recorderSettings.lidarDepthEnabled,
                    "directory": "lidar_depth",
                    "index_file": "lidar_depth_info.csv",
                    "pixel_format": "DepthUInt16",
                    "depth_unit": "millimeter",
                    "depth_scale": 1000,
                    "filtering_enabled": true,
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "raw_layout": "16-bit grayscale PNG depth map; value 0 means invalid, value / depth_scale gives meters",
                    "pixel_orientation": recorderSettings.captureMode == .arkit
                        ? "ARKit native landscape; aligned with wide.mp4"
                        : "Landscape Right",
                    "intrinsics": recorderSettings.captureMode == .arkit
                        ? "scaled to the depth-map resolution in the native pixel layout"
                        : "scaled to the depth-map resolution",
                    "schema": [
                        "frame_index",
                        "sensor_sec",
                        "utc_sec",
                        "file_name",
                        "width_px",
                        "height_px",
                        "pixel_format",
                        "bytes_per_pixel",
                        "depth_unit",
                        "depth_scale",
                        "min_depth_m",
                        "max_depth_m",
                        "fx_px",
                        "fy_px",
                        "cx_px",
                        "cy_px"
                    ]
                ],
                "accelerometer": [
                    "enabled": recorderSettings.imuEnabled,
                    "file": "accelerometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "ax_m_s2", "ay_m_s2", "az_m_s2"],
                    "source_unit": "CoreMotion g",
                    "acceleration_conversion": "Negative CoreMotion raw acceleration: -g * 9.80665 m/s^2; gyroscope unchanged"
                ],
                "gyroscope": [
                    "enabled": recorderSettings.imuEnabled,
                    "file": "gyroscope.csv",
                    "schema": ["sensor_sec", "utc_sec", "gx_rad_s", "gy_rad_s", "gz_rad_s"]
                ],
                "imu": [
                    "enabled": recorderSettings.imuEnabled,
                    "file": "imu.csv",
                    "schema": ["sensor_sec", "utc_sec", "ax_m_s2", "ay_m_s2", "az_m_s2", "gx_rad_s", "gy_rad_s", "gz_rad_s", "accel_sensor_sec", "gyro_sensor_sec"],
                    "note": "Rows are keyed by gyro samples with the latest raw accelerometer sample attached.",
                    "acceleration_conversion": "Negative CoreMotion raw acceleration: -g * 9.80665 m/s^2; gyroscope unchanged"
                ],
                "device_motion": [
                    "enabled": recorderSettings.deviceMotionEnabled,
                    "file": "device_motion.csv",
                    "source": "CoreMotion fused device motion, not raw IMU",
                    "reference_frame": "xArbitraryCorrectedZVertical",
                    "nominal_hz": 100,
                    "schema": [
                        "sensor_sec",
                        "utc_sec",
                        "qw",
                        "qx",
                        "qy",
                        "qz",
                        "roll",
                        "pitch",
                        "yaw",
                        "gravity_x_m_s2",
                        "gravity_y_m_s2",
                        "gravity_z_m_s2",
                        "user_accel_x_m_s2",
                        "user_accel_y_m_s2",
                        "user_accel_z_m_s2",
                        "rotation_rate_x_rad_s",
                        "rotation_rate_y_rad_s",
                        "rotation_rate_z_rad_s",
                        "magnetic_field_x_uT",
                        "magnetic_field_y_uT",
                        "magnetic_field_z_uT",
                        "magnetic_accuracy",
                        "heading_deg"
                    ],
                    "acceleration_conversion": "CoreMotion g converted to m/s^2 using 9.80665"
                ],
                "magnetometer": [
                    "enabled": recorderSettings.magnetometerEnabled,
                    "file": "magnetometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "mx_uT", "my_uT", "mz_uT"]
                ],
                "barometer": [
                    "enabled": recorderSettings.barometerEnabled,
                    "file": "barometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "pressure_kpa", "relative_altitude_m"]
                ],
                "geo_location": [
                    "enabled": recorderSettings.geoLocationEnabled,
                    "file": "geo_location.csv",
                    "source": "CoreLocation fused geographic location, not raw GNSS measurements",
                    "schema": [
                        "sensor_sec",
                        "utc_sec",
                        "latitude",
                        "longitude",
                        "altitude",
                        "horizontal_accuracy_m",
                        "vertical_accuracy_m",
                        "speed_m_s",
                        "speed_accuracy_m_s",
                        "course_deg",
                        "course_accuracy_deg",
                        "valid_position",
                        "valid_altitude",
                        "valid_speed",
                        "valid_course",
                        "source_is_simulated",
                        "source_is_accessory"
                    ]
                ]
            ]
        ]

        do {
            guard JSONSerialization.isValidJSONObject(meta) else {
                os_log("meta.json object is not valid JSON.", type: .error)
                return
            }
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metaURL, options: .atomic)
        } catch {
            os_log("Cannot write meta.json: %@", type: .error, error.localizedDescription)
        }
    }

    private func updateDiskCapacity() {
        do {
            let capacityValues = try getRecDir().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacityBytes = capacityValues.volumeAvailableCapacityForImportantUsage {
                let limit = 100
                if capacityBytes > (limit * 1024 * 1024 * 1024) {
                    diskCapacity = String(format: "%d+ GB", limit)
                } else {
                    diskCapacity = ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file)
                }
            }
        } catch {
        }
    }

    private func getRecDir() -> URL {
        return try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
}

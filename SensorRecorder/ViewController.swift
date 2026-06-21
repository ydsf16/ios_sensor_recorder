import UIKit
import AVFoundation
import CoreLocation
import CoreMotion
import os.log
import simd

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

private final class CameraStreamRecorder {
    private let videoURL: URL
    private let infoURL: URL
    private let cameraName: String
    private let includeAudioTrack: Bool
    private let expectedFrameRate: Double
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

    init(cameraName: String, videoURL: URL, infoURL: URL, includeAudioTrack: Bool, expectedFrameRate: Double) {
        self.cameraName = cameraName
        self.videoURL = videoURL
        self.infoURL = infoURL
        self.includeAudioTrack = includeAudioTrack
        self.expectedFrameRate = expectedFrameRate
        self.utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: infoURL)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("# camera,\(cameraName)")
    }

    func append(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice?, sessionClock: CMClock?) {
        guard !isFinishing else { return }
        if writer == nil {
            configureWriter(sampleBuffer)
        }
        guard let writer = writer, let input = input else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }

        if writer.status == .writing && input.isReadyForMoreMediaData {
            guard input.append(sampleBuffer) else {
                writeInfoLine("# append_failed \(frameIndex) \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            writeInfo(sampleBuffer, device: device, sessionClock: sessionClock)
            frameIndex += 1
        } else if writer.status == .failed {
            writeInfoLine("# writer_failed \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing,
              let firstPTS = firstPTS,
              let writer = writer,
              let audioInput = audioInput else {
            return
        }
        guard writer.status == .writing else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= firstPTS else { return }
        if audioInput.isReadyForMoreMediaData {
            guard audioInput.append(sampleBuffer) else {
                writeInfoLine("# audio_append_failed \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
        }
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
        audioInput?.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    func writeDeviceFormat(_ device: AVCaptureDevice?) {
        guard let device = device else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        writeInfoLine("# active_format,\(dimensions.width)x\(dimensions.height),fps,\(String(format: "%.3f", expectedFrameRate))")
    }

    private func configureWriter(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        do {
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            let settings = Self.videoOutputSettings(width: width, height: height)
            let codec = settings[AVVideoCodecKey] as? AVVideoCodecType ?? .h264
            videoCodec = codec
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canApply(outputSettings: settings, forMediaType: .video),
                  writer.canAdd(input) else {
                writeInfoLine("# writer_input_failed")
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
                }
            }
            self.writer = writer
            self.input = input
            writeInfoLine("# video,\(width)x\(height),codec,\(codec.rawValue)")
            writeCSVHeaderIfNeeded()
        } catch {
            writeInfoLine("# writer_init_failed \(error.localizedDescription)")
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
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        let pixels = width * height

        // AVAssetWriter may accept photo-sized dimensions during a static probe,
        // but real-time MP4 recording is much less forgiving. Keep the settings
        // menu on known video-safe envelopes and filter photo-ish 4:3 formats
        // such as 2592x1944 or 4032x3024 until we add a live format probe.
        let aspect = Double(longEdge) / Double(shortEdge)
        let isFourByThree = abs(aspect - (4.0 / 3.0)) < 0.03
        let isSixteenByNine = abs(aspect - (16.0 / 9.0)) < 0.03

        if isFourByThree {
            guard longEdge <= 1920, shortEdge <= 1440 else { return false }
        } else if isSixteenByNine {
            guard longEdge <= 3840, shortEdge <= 2160, pixels <= 3840 * 2160 else { return false }
        } else {
            return false
        }

        guard pixels <= 3840 * 2160 else {
            return false
        }

        return canEncodeMP4(width: width, height: height)
    }

    fileprivate static func preferredVideoCodec(width: Int, height: Int) -> AVVideoCodecType {
        let exceedsH264UHDEnvelope = width > 3840 || height > 2160 || width * height > 3840 * 2160
        return exceedsH264UHDEnvelope ? .hevc : .h264
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

    private static func videoBitRate(width: Int, height: Int, codec: AVVideoCodecType) -> Int {
        let pixels = width * height
        let bitsPerPixel = codec == .hevc ? 3 : 4
        return max(pixels * bitsPerPixel, 2_000_000)
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

    private func writeInfo(_ sampleBuffer: CMSampleBuffer, device: AVCaptureDevice?, sessionClock: CMClock?) {
        writeCSVHeaderIfNeeded()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sensorTime = captureSensorTime(for: presentationTime, sessionClock: sessionClock)
        let sensorSec = CMTimeGetSeconds(sensorTime)
        let utcSec = sensorSec + utcMinusSensorOffsetSec
        let exposureSec = device.map { CMTimeGetSeconds($0.exposureDuration) } ?? .nan
        let iso = device?.iso ?? .nan

        var width = 0
        var height = 0
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            width = CVPixelBufferGetWidth(imageBuffer)
            height = CVPixelBufferGetHeight(imageBuffer)
        }

        let intrinsics = cameraIntrinsics(sampleBuffer)
        let fx = intrinsics?.fx ?? .nan
        let fy = intrinsics?.fy ?? .nan
        let cx = intrinsics?.cx ?? .nan
        let cy = intrinsics?.cy ?? .nan
        writeInfoLine(String(
            format: "%d,%.9f,%.9f,%.9f,%.3f,%d,%d,%.9f,%.9f,%.9f,%.9f",
            frameIndex, sensorSec, utcSec, exposureSec, iso, width, height, fx, fy, cx, cy
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
        guard let data = (line + "\n").data(using: .utf8) else { return }
        infoHandle?.write(data)
    }

    private func writeCSVHeaderIfNeeded() {
        guard !didWriteCSVHeader else { return }
        didWriteCSVHeader = true
        writeInfoLine("frame_index,sensor_sec,utc_sec,exposure_sec,iso,width_px,height_px,fx_px,fy_px,cx_px,cy_px")
    }
}

private final class AudioStreamRecorder {
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
        writeInfoLine("frame_index,sensor_sec,utc_sec,duration_sec,sample_count,sample_rate_hz,channels")
    }

    func append(_ sampleBuffer: CMSampleBuffer, sessionClock: CMClock?) {
        guard !isFinishing else { return }
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
                writeInfoLine("# append_failed,\(frameIndex),\(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            let sensorSec = writeInfo(sampleBuffer, sessionClock: sessionClock)
            recordSample(sensorSec)
            frameIndex += 1
        } else if writer.status == .failed {
            writeInfoLine("# writer_failed,\(writer.error?.localizedDescription ?? "unknown")")
        }
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
                writeInfoLine("# writer_input_failed,aac")
                return
            }
            writer.add(input)
            self.writer = writer
            self.input = input
            writeInfoLine("# audio,aac,m4a")
        } catch {
            writeInfoLine("# writer_init_failed,\(error.localizedDescription)")
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
            format: "%d,%.9f,%.9f,%.9f,%d,%.3f,%d",
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
        infoHandle?.write(data)
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
            let ax = self.metersPerSecondSquared(fromG: data.acceleration.x)
            let ay = self.metersPerSecondSquared(fromG: data.acceleration.y)
            let az = self.metersPerSecondSquared(fromG: data.acceleration.z)
            self.recordAccelerometerSample(sensorSec)
            self.latestAccelerometerSample = AccelerometerSample(
                sensorSec: sensorSec,
                utcSec: utcSec,
                x: ax,
                y: ay,
                z: az
            )
            self.accelerometerWriter?.writeLine(String(
                format: "%.9f,%.9f,%.9f,%.9f,%.9f",
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
                format: "%.9f,%.9f,%.9f,%.9f,%.9f",
                sensorSec, utcSec, data.rotationRate.x, data.rotationRate.y, data.rotationRate.z
            ))
            guard let accelerometer = self.latestAccelerometerSample else {
                return
            }
            self.recordIMUSample(sensorSec)
            self.imuWriter?.writeLine(String(
                format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f",
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
                format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%d,%.9f",
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
                format: "%.9f,%.9f,%.9f,%.9f,%.9f",
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
                format: "%.9f,%.9f,%.9f,%.9f",
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
            format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.3f,%.3f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d,%d",
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

class ViewController: UIViewController, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, CLLocationManagerDelegate {
    private enum RecordingCamera {
        case wide
        case ultraWide
    }

    private struct PendingStartFrame {
        let sampleBuffer: CMSampleBuffer
        let sensorSec: TimeInterval
    }

    private enum PreviewDebugMode: String {
        case wideOnly = "wide only"
        case ultraWideOnly = "ultrawide only"
        case dual = "dual preview"
    }

    private struct CameraCaptureSettings: Codable {
        var enabled: Bool
        var resolution: String
        var frameRate: String
        var autoFocus: Bool
    }

    private struct RecorderSettings: Codable {
        var wide: CameraCaptureSettings
        var ultraWide: CameraCaptureSettings
        var imuEnabled: Bool
        var magnetometerEnabled: Bool
        var barometerEnabled: Bool
        var geoLocationEnabled: Bool
        var deviceMotionEnabled: Bool
        var audioEnabled: Bool
        var storageFormat: String

        static let defaults = RecorderSettings(
            wide: CameraCaptureSettings(enabled: true, resolution: "1920x1440", frameRate: "30", autoFocus: false),
            ultraWide: CameraCaptureSettings(enabled: true, resolution: "1920x1440", frameRate: "30", autoFocus: false),
            imuEnabled: true,
            magnetometerEnabled: true,
            barometerEnabled: true,
            geoLocationEnabled: true,
            deviceMotionEnabled: true,
            audioEnabled: true,
            storageFormat: "CSV"
        )

        private static let storageKey = "sensor_recorder.settings.v1"
        private static let configFileName = "sensor_recorder_settings.json"

        static func load() -> RecorderSettings {
            if let data = try? Data(contentsOf: configFileURL),
               let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data) {
                return settings
            }
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data) else {
                return defaults
            }
            return settings
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
    private var recorderSettings = RecorderSettings.load()
    private var settingsMenuButtons: [String: UIButton] = [:]
    private var settingsSwitches: [String: UISwitch] = [:]
    private var cameraSettingsGroups: [String: UIView] = [:]
    private weak var settingsRailButton: UIButton?
    private weak var filesRailButton: UIButton?
    private var cameraStatusRows: [String: UILabel] = [:]
    private var sensorStatusRows: [String: UILabel] = [:]
    private var captureStatusRows: [String: UILabel] = [:]
    private var cameraStatusBadges: [String: UIView] = [:]
    private var captureStatusBadges: [String: UIView] = [:]
    private var rightControlRail: UIView?
    private var sensorMonitorBar: UIView?
    private var hudContentRect: CGRect = .zero
    private let overlayFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private let overlayValueFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    private lazy var session = AVCaptureMultiCamSession()
    private var singlePreviewSession: AVCaptureSession?
    private var singlePreviewLayer: AVCaptureVideoPreviewLayer?
    private var singlePreviewView: CameraPreviewView?
    private var wideCameraPreviewView: CameraPreviewView?
    private var ultraWideCameraPreviewView: CameraPreviewView?
    private var singleVideoOutput: AVCaptureVideoDataOutput?
    private var singleFrameCount = 0
    private var diagnosticLayer: CALayer?
    private let sessionQueue = DispatchQueue(label: "com.ydsf16.sensorrecorder.capture")

    private var wideOutput: AVCaptureMovieFileOutput?
    private var ultraWideOutput: AVCaptureMovieFileOutput?
    private var wideVideoPort: AVCaptureInput.Port?
    private var ultraWideVideoPort: AVCaptureInput.Port?
    private var wideDevice: AVCaptureDevice?
    private var ultraWideDevice: AVCaptureDevice?
    private var widePreviewOutput: AVCaptureVideoDataOutput?
    private var ultraWidePreviewOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var wideRecorder: CameraStreamRecorder?
    private var ultraWideRecorder: CameraStreamRecorder?
    private var audioRecorder: AudioStreamRecorder?
    private var sensorRecorder: SensorStreamRecorder?
    private let locationManager = CLLocationManager()
    private var locationRecorder: GeoLocationStreamRecorder?
    private var wideDisplayLayer: AVSampleBufferDisplayLayer?
    private var ultraWideDisplayLayer: AVSampleBufferDisplayLayer?
    private var wideFrameCount = 0
    private var ultraWideFrameCount = 0
    private var widePreviewLayer: AVCaptureVideoPreviewLayer?
    private var ultraWidePreviewLayer: AVCaptureVideoPreviewLayer?

    private var isConfigured = false
    private var isRecordingConfigured = false
    private var isRecording = false
    private var recordingStartAligned = false
    private var pendingWideStartFrame: PendingStartFrame?
    private var pendingUltraWideStartFrame: PendingStartFrame?
    private var pendingLocationPermissionCompletion: ((Bool) -> Void)?
    private let recordingStartToleranceSec: TimeInterval = 1.0 / 60.0
    private let embedAudioInCameraMP4 = false
    private let previewOnlyMode = false
    private let previewDebugMode: PreviewDebugMode = .dual
    private var observesSessionRuntimeErrors = false
    private var pendingMovieFinishes = 0

    private var outDirURL: URL!
    private var diskCapacity: String = "?"
    private var startTime: Date!
    private var recordingTimer: Timer?
    private var recBlinkTimer: Timer?
    private var recBlinkVisible = true

    private var hasEnabledCamera: Bool {
        recorderSettings.wide.enabled || recorderSettings.ultraWide.enabled
    }

    private var needsRunningCaptureSession: Bool {
        hasEnabledCamera || recorderSettings.audioEnabled
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        recorderSettings = RecorderSettings.load()
        view.backgroundColor = .black
        updateDiskCapacity()
        installLandscapeOverlay()
        initializeUI()
        startStopButton.isEnabled = false
        sceneView.backgroundColor = .black
        sceneView.layer.borderWidth = 0
        configureLocationManager()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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

    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        ensurePermission(.camera, completion: completion)
    }

    private func requestAudioAccess(_ completion: @escaping (Bool) -> Void) {
        ensurePermission(.microphone, completion: completion)
    }

    private func requiredPermissions(for settings: RecorderSettings) -> [CapturePermission] {
        var permissions: [CapturePermission] = []
        if settings.wide.enabled || settings.ultraWide.enabled {
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
        showError(msg: message)
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
        setStatus("Preview")
        let cameraEnabled = recorderSettings.wide.enabled || recorderSettings.ultraWide.enabled

        let configureAfterCameraPermission: () -> Void = {
            if self.previewDebugMode == .wideOnly {
                self.configureSingleCameraPreview()
                return
            }

            let configurePreview: (Bool) -> Void = { includeAudio in
                self.sessionQueue.async {
                    self.configurePreviewSession(includeAudio: includeAudio)
                    guard self.isConfigured else { return }
                    if self.needsRunningCaptureSession {
                        self.session.startRunning()
                    }
                    DispatchQueue.main.async {
                        self.startStopButton.isEnabled = true
                    }
                    let ready = self.needsRunningCaptureSession ? self.session.isRunning : true
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
            guard granted else { return }
            configureAfterCameraPermission()
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let audioOutput = audioOutput, output === audioOutput {
            if isRecording {
                appendAudioSample(sampleBuffer)
            }
            return
        }

        if let wideOutput = widePreviewOutput, output === wideOutput {
            wideFrameCount += 1
            enqueue(sampleBuffer, on: wideDisplayLayer)
            if isRecording {
                handleRecordingSample(sampleBuffer, camera: .wide)
            }
            guard wideFrameCount % 30 == 0 else { return }
            setStatus("Frames")
            return
        }

        if let ultraWideOutput = ultraWidePreviewOutput, output === ultraWideOutput {
            ultraWideFrameCount += 1
            enqueue(sampleBuffer, on: ultraWideDisplayLayer)
            if isRecording {
                handleRecordingSample(sampleBuffer, camera: .ultraWide)
            }
            guard ultraWideFrameCount % 30 == 0 else { return }
            setStatus("Frames")
            return
        }

        singleFrameCount += 1
        guard singleFrameCount % 30 == 0 else { return }
        setStatus("Frames \(singleFrameCount)")
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

    private func handleRecordingSample(_ sampleBuffer: CMSampleBuffer, camera: RecordingCamera) {
        guard shouldSynchronizeRecordingStart() else {
            appendRecordingSample(sampleBuffer, camera: camera)
            return
        }

        guard !recordingStartAligned else {
            appendRecordingSample(sampleBuffer, camera: camera)
            return
        }

        let sensorSec = sensorSeconds(for: sampleBuffer)
        guard sensorSec.isFinite else {
            recordingStartAligned = true
            appendRecordingSample(sampleBuffer, camera: camera)
            return
        }

        let pendingFrame = PendingStartFrame(sampleBuffer: sampleBuffer, sensorSec: sensorSec)
        switch camera {
        case .wide:
            pendingWideStartFrame = pendingFrame
        case .ultraWide:
            pendingUltraWideStartFrame = pendingFrame
        }
        alignPendingRecordingStartIfNeeded()
    }

    private func alignPendingRecordingStartIfNeeded() {
        guard let wideFrame = pendingWideStartFrame,
              let ultraWideFrame = pendingUltraWideStartFrame else {
            return
        }

        let delta = wideFrame.sensorSec - ultraWideFrame.sensorSec
        guard abs(delta) <= recordingStartToleranceSec else {
            if delta < 0 {
                pendingWideStartFrame = nil
            } else {
                pendingUltraWideStartFrame = nil
            }
            return
        }

        recordingStartAligned = true
        pendingWideStartFrame = nil
        pendingUltraWideStartFrame = nil
        appendRecordingSample(wideFrame.sampleBuffer, camera: .wide)
        appendRecordingSample(ultraWideFrame.sampleBuffer, camera: .ultraWide)
    }

    private func shouldSynchronizeRecordingStart() -> Bool {
        // Keep recording responsive. Offline pairing should use per-frame host timestamps
        // from info.csv instead of blocking either stream at the first frame.
        return false
    }

    private func appendRecordingSample(_ sampleBuffer: CMSampleBuffer, camera: RecordingCamera) {
        switch camera {
        case .wide:
            wideRecorder?.append(sampleBuffer, device: wideDevice, sessionClock: captureSessionClock())
        case .ultraWide:
            ultraWideRecorder?.append(sampleBuffer, device: ultraWideDevice, sessionClock: captureSessionClock())
        }
    }

    private func resetRecordingStartAlignment() {
        recordingStartAligned = false
        pendingWideStartFrame = nil
        pendingUltraWideStartFrame = nil
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer, on displayLayer: AVSampleBufferDisplayLayer?) {
        guard let displayLayer = displayLayer else { return }
        DispatchQueue.main.async {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func captureSessionClock() -> CMClock? {
        return session.synchronizationClock
    }

    private func sensorSeconds(for sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let sessionClock = captureSessionClock() else {
            return CMTimeGetSeconds(presentationTime)
        }
        let sensorTime = CMSyncConvertTime(presentationTime, from: sessionClock, to: CMClockGetHostTimeClock())
        return CMTimeGetSeconds(sensorTime)
    }

    private func configurePreviewSession(includeAudio: Bool) {
        guard !isConfigured else { return }
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            showError(msg: "This device does not support MultiCam capture.")
            return
        }

        observeSessionRuntimeErrorsIfNeeded()

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let wideEnabled = recorderSettings.wide.enabled
        let ultraWideEnabled = recorderSettings.ultraWide.enabled
        let dualCameraCapture = wideEnabled && ultraWideEnabled

        if (previewDebugMode == .wideOnly || previewDebugMode == .dual) && wideEnabled {
            guard configurePreviewCamera(
                deviceType: .builtInWideAngleCamera,
                cameraName: "wide",
                previewIndex: 0,
                settings: recorderSettings.wide,
                requiresMultiCamFormat: dualCameraCapture
            ) else {
                os_log("Failed to configure wide camera.", type: .error)
                showError(msg: "Failed to configure wide camera.")
                return
            }
        }

        if (previewDebugMode == .ultraWideOnly || previewDebugMode == .dual) && ultraWideEnabled {
            guard configurePreviewCamera(
                deviceType: .builtInUltraWideCamera,
                cameraName: "ultrawide",
                previewIndex: 1,
                settings: recorderSettings.ultraWide,
                requiresMultiCamFormat: dualCameraCapture
            ) else {
                os_log("Failed to configure ultra-wide camera.", type: .error)
                showError(msg: "Failed to configure ultra-wide camera.")
                return
            }
        }

        if includeAudio {
            configureAudioSessionForCapture()
            configureAudioCapture()
        }

        reduceFormatsForMulticamBudgetIfNeeded()
        isConfigured = true
        setStatus(previewDebugMode.rawValue)
    }

    private func observeSessionRuntimeErrorsIfNeeded() {
        guard !observesSessionRuntimeErrors else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        observesSessionRuntimeErrors = true
    }

    private func configurePreviewCamera(
        deviceType: AVCaptureDevice.DeviceType,
        cameraName: String,
        previewIndex: Int,
        settings: CameraCaptureSettings,
        requiresMultiCamFormat: Bool
    ) -> Bool {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
            os_log("Camera unavailable: %@", type: .error, deviceType.rawValue)
            return false
        }

        do {
            try configureDeviceForPreview(device, settings: settings, requiresMultiCamFormat: requiresMultiCamFormat)
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInputWithNoConnections(input)

            guard let videoPort = input.ports.first(where: { $0.mediaType == .video }) else {
                return false
            }

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(videoOutput) else { return false }
            session.addOutputWithNoConnections(videoOutput)

            let videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: videoOutput)
            guard session.canAddConnection(videoConnection) else { return false }
            session.addConnection(videoConnection)
            configureVideoConnection(videoConnection)
            if videoConnection.isCameraIntrinsicMatrixDeliverySupported {
                videoConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }

            DispatchQueue.main.async {
                let displayLayer = self.makeDisplayLayer(for: cameraName)
                self.sceneView.layer.insertSublayer(displayLayer, at: 0)
                if cameraName == "wide" {
                    self.wideDisplayLayer = displayLayer
                } else {
                    self.ultraWideDisplayLayer = displayLayer
                }
                self.layoutPreviewLayers()
                self.view.bringSubviewToFront(self.startStopButton.superview ?? self.startStopButton)
            }

            if cameraName == "wide" {
                wideVideoPort = videoPort
                wideDevice = device
                widePreviewOutput = videoOutput
            } else {
                ultraWideVideoPort = videoPort
                ultraWideDevice = device
                ultraWidePreviewOutput = videoOutput
            }
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

    private func makePreviewView(for cameraName: String) -> CameraPreviewView {
        if Thread.isMainThread {
            return createPreviewView(for: cameraName)
        }

        var previewView: CameraPreviewView!
        DispatchQueue.main.sync {
            previewView = createPreviewView(for: cameraName)
        }
        return previewView
    }

    private func createPreviewView(for cameraName: String) -> CameraPreviewView {
        let previewView = CameraPreviewView(frame: .zero)
        previewView.backgroundColor = .black
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.previewLayer.videoGravity = .resizeAspect
        previewView.previewLayer.backgroundColor = previewView.backgroundColor?.cgColor
        return previewView
    }

    private func configureRecordingOutputs() -> Bool {
        guard !isRecordingConfigured else { return true }
        guard let wideVideoPort = wideVideoPort, let ultraWideVideoPort = ultraWideVideoPort else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let wideMovieOutput = makeMovieOutput(for: wideVideoPort) else {
            showError(msg: "Failed to configure wide video writer.")
            return false
        }
        guard let ultraWideMovieOutput = makeMovieOutput(for: ultraWideVideoPort) else {
            showError(msg: "Failed to configure ultra-wide video writer.")
            return false
        }

        wideOutput = wideMovieOutput
        ultraWideOutput = ultraWideMovieOutput
        isRecordingConfigured = true
        return true
    }

    private func makeMovieOutput(for videoPort: AVCaptureInput.Port) -> AVCaptureMovieFileOutput? {
        let movieOutput = AVCaptureMovieFileOutput()
        movieOutput.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        guard session.canAddOutput(movieOutput) else { return nil }
        session.addOutputWithNoConnections(movieOutput)

        let connection = AVCaptureConnection(inputPorts: [videoPort], output: movieOutput)
        guard session.canAddConnection(connection) else { return nil }
        session.addConnection(connection)
        configureVideoConnection(connection)
        return movieOutput
    }

    private func configureDeviceForPreview(
        _ device: AVCaptureDevice,
        settings: CameraCaptureSettings,
        requiresMultiCamFormat: Bool
    ) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if let format = preferredFormats(for: device, settings: settings, requiresMultiCamFormat: requiresMultiCamFormat).first {
            device.activeFormat = format
        }

        let fps = supportedFrameRate(for: device.activeFormat, requested: clampedFrameRate(from: settings.frameRate))
        let duration = frameDuration(for: fps)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        if settings.autoFocus {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        } else if device.isFocusModeSupported(.locked) {
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(
                    lensPosition: lensPosition(forFocusDistanceMeters: 1.5),
                    completionHandler: nil
                )
            } else {
                device.focusMode = .locked
            }
        }
    }

    private func lensPosition(forFocusDistanceMeters meters: Double) -> Float {
        let safeMeters = max(meters, 0.1)
        return Float(min(max(1.0 / safeMeters, 0.0), 1.0))
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

            let targetFPS = clampedFrameRate(from: settings.frameRate)
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
        guard let fps = Double(value), fps.isFinite else {
            return 30
        }
        return min(max(fps, 0.1), 60)
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
        guard let device = device else {
            return clampedFrameRate(from: settings.frameRate)
        }
        return supportedFrameRate(for: device.activeFormat, requested: clampedFrameRate(from: settings.frameRate))
    }

    private func frameDuration(for fps: Double) -> CMTime {
        let scale: Int32 = 600
        let value = max(Int64(round(Double(scale) / max(fps, 0.1))), 1)
        return CMTime(value: value, timescale: scale)
    }

    private func reduceFormatsForMulticamBudgetIfNeeded() {
        guard previewDebugMode == .dual,
              let wideDevice = wideDevice,
              let ultraWideDevice = ultraWideDevice else {
            return
        }

        while session.hardwareCost > 1.0 || session.systemPressureCost > 1.0 {
            let wideArea = activeFormatArea(for: wideDevice)
            let ultraWideArea = activeFormatArea(for: ultraWideDevice)
            let firstChoice = wideArea >= ultraWideArea ? wideDevice : ultraWideDevice
            let secondChoice = wideArea >= ultraWideArea ? ultraWideDevice : wideDevice

            if downgradeFormat(for: firstChoice) {
                continue
            }
            if downgradeFormat(for: secondChoice) {
                continue
            }
            os_log(
                "MultiCam cost remains high. hardwareCost %.3f systemPressureCost %.3f",
                type: .error,
                session.hardwareCost,
                session.systemPressureCost
            )
            break
        }
    }

    private func downgradeFormat(for device: AVCaptureDevice) -> Bool {
        let settings = device === wideDevice ? recorderSettings.wide : recorderSettings.ultraWide
        let formats = preferredFormats(for: device, settings: settings, requiresMultiCamFormat: true)
        guard let currentIndex = formats.firstIndex(where: { $0 === device.activeFormat }),
              currentIndex + 1 < formats.count else {
            return false
        }

        let nextFormat = formats[currentIndex + 1]
        do {
            try device.lockForConfiguration()
            device.activeFormat = nextFormat
            let fps = supportedFrameRate(for: nextFormat, requested: clampedFrameRate(from: settings.frameRate))
            let duration = frameDuration(for: fps)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            return true
        } catch {
            os_log("Failed to downgrade camera format: %@", type: .error, error.localizedDescription)
            return false
        }
    }

    private func activeFormatArea(for device: AVCaptureDevice) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return Int(dimensions.width) * Int(dimensions.height)
    }

    private func cameraResolutionOptions(for device: AVCaptureDevice?, requiresMultiCamFormat: Bool) -> [String] {
        guard let device = device else {
            return ["3840x2160", "1920x1440", "1920x1080", "1280x960", "1280x720", "640x480"]
        }

        let options = device.formats.compactMap { format -> (label: String, area: Int)? in
            guard !requiresMultiCamFormat || format.isMultiCamSupported else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            guard width > 0, height > 0 else { return nil }
            guard width >= 640 && height >= 480 else { return nil }
            guard CameraStreamRecorder.isRecordableMP4Resolution(width: width, height: height) else { return nil }
            return ("\(width)x\(height)", width * height)
        }

        let unique = Dictionary(options.map { ($0.label, $0.area) }, uniquingKeysWith: max)
        let sorted = unique.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key > rhs.key
        }
        var labels = sorted.map(\.key)
        if !labels.contains("640x480") {
            labels.append("640x480")
        }
        return labels.isEmpty ? ["3840x2160", "1920x1440", "1920x1080", "1280x960", "1280x720", "640x480"] : labels
    }

    private func configureVideoConnection(_ connection: AVCaptureConnection) {
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }

    private func applyRecordingCameraSettings() {
        let requiresMultiCamFormat = recorderSettings.wide.enabled && recorderSettings.ultraWide.enabled
        if let wideDevice {
            do {
                try configureDeviceForPreview(
                    wideDevice,
                    settings: recorderSettings.wide,
                    requiresMultiCamFormat: requiresMultiCamFormat
                )
            } catch {
                os_log("Failed to apply wide recording settings: %@", type: .error, error.localizedDescription)
            }
        }
        if let ultraWideDevice {
            do {
                try configureDeviceForPreview(
                    ultraWideDevice,
                    settings: recorderSettings.ultraWide,
                    requiresMultiCamFormat: requiresMultiCamFormat
                )
            } catch {
                os_log("Failed to apply ultra-wide recording settings: %@", type: .error, error.localizedDescription)
            }
        }
    }

    private func layoutPreviewLayers() {
        let bounds = sceneView.bounds
        diagnosticLayer?.frame = bounds.insetBy(dx: 24, dy: 24)
        singlePreviewView?.frame = bounds
        singlePreviewLayer?.frame = bounds

        if previewDebugMode != .dual {
            layoutSampleBufferDisplayLayer(wideDisplayLayer, in: bounds)
            layoutSampleBufferDisplayLayer(ultraWideDisplayLayer, in: bounds)
            wideCameraPreviewView?.frame = bounds
            ultraWideCameraPreviewView?.frame = bounds
            widePreviewLayer?.frame = wideCameraPreviewView?.bounds ?? bounds
            ultraWidePreviewLayer?.frame = ultraWideCameraPreviewView?.bounds ?? bounds
            return
        }

        hudContentRect = dualCameraContentRect(in: bounds)
        let wideEnabled = recorderSettings.wide.enabled
        let ultraEnabled = recorderSettings.ultraWide.enabled
        let halfWidth = hudContentRect.width / 2
        let ultraFrame: CGRect
        let wideFrame: CGRect
        if wideEnabled && ultraEnabled {
            ultraFrame = CGRect(x: hudContentRect.minX, y: hudContentRect.minY, width: halfWidth, height: hudContentRect.height)
            wideFrame = CGRect(x: hudContentRect.midX, y: hudContentRect.minY, width: halfWidth, height: hudContentRect.height)
        } else if wideEnabled {
            wideFrame = hudContentRect
            ultraFrame = .zero
        } else if ultraEnabled {
            ultraFrame = hudContentRect
            wideFrame = .zero
        } else {
            wideFrame = .zero
            ultraFrame = .zero
        }
        layoutSampleBufferDisplayLayer(wideDisplayLayer, in: wideFrame)
        layoutSampleBufferDisplayLayer(ultraWideDisplayLayer, in: ultraFrame)
        wideCameraPreviewView?.frame = wideFrame
        ultraWideCameraPreviewView?.frame = ultraFrame
        widePreviewLayer?.frame = wideCameraPreviewView?.bounds ?? .zero
        ultraWidePreviewLayer?.frame = ultraWideCameraPreviewView?.bounds ?? .zero
        layoutHUDOverlays(wideFrame: wideFrame, ultraFrame: ultraFrame)
    }

    private func dualCameraContentRect(in bounds: CGRect) -> CGRect {
        let targetAspect: CGFloat = 8.0 / 3.0
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

    private func layoutHUDOverlays(wideFrame: CGRect, ultraFrame: CGRect) {
        guard !cameraStatusRows.isEmpty || !captureStatusRows.isEmpty else { return }
        cameraStatusBadges["ultra"]?.isHidden = ultraFrame.isEmpty
        cameraStatusBadges["wide"]?.isHidden = wideFrame.isEmpty
        if !ultraFrame.isEmpty {
            cameraStatusBadges["ultra"]?.frame = CGRect(x: ultraFrame.midX - 174, y: ultraFrame.minY + 2, width: 348, height: 30)
        }
        if !wideFrame.isEmpty {
            cameraStatusBadges["wide"]?.frame = CGRect(x: wideFrame.midX - 150, y: wideFrame.minY + 2, width: 300, height: 30)
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
        captureStatusBadges["summary"].map { view.bringSubviewToFront($0) }
        if let sensorMonitorBar {
            view.bringSubviewToFront(sensorMonitorBar)
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
            self.frameCounterLabel.text = "\(self.previewDebugMode.rawValue), \(running), W \(self.wideFrameCount), U \(self.ultraWideFrameCount), S \(self.singleFrameCount), \(Int(frame.width))x\(Int(frame.height))"
            self.refreshOverlayStatus()
        }
    }

    private func startRecording() {
        let startClock = CACurrentMediaTime()
        logRecordingStartStep("tap", startClock: startClock)
        startStopButton.isEnabled = false
        timeLabel.text = "Preparing"

        ensurePermissions(requiredPermissions(for: recorderSettings)) { granted in
            DispatchQueue.main.async {
                self.logRecordingStartStep("permissions", startClock: startClock)
                guard granted else {
                    self.startStopButton.isEnabled = true
                    self.timeLabel.text = "Permission needed"
                    return
                }
                self.startRecordingAfterPermissionChecks(startClock: startClock)
            }
        }
    }

    private func startRecordingAfterPermissionChecks(startClock: CFTimeInterval) {
        let captureSessionReady = needsRunningCaptureSession ? session.isRunning : true
        guard isConfigured && captureSessionReady else {
            startStopButton.isEnabled = true
            showError(msg: needsRunningCaptureSession ? "Capture session is not ready yet." : "Recorder is not ready yet.")
            return
        }

        guard createFiles() else {
            startStopButton.isEnabled = true
            showError(msg: "Failed to create the recording directory.")
            return
        }
        logRecordingStartStep("files", startClock: startClock)

        sessionQueue.async {
            self.resetRecordingStartAlignment()

            if self.recorderSettings.wide.enabled {
                self.wideRecorder = CameraStreamRecorder(
                    cameraName: "wide",
                    videoURL: self.outDirURL.appendingPathComponent("wide.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("wide_info.csv"),
                    includeAudioTrack: self.embedAudioInCameraMP4 && self.recorderSettings.audioEnabled,
                    expectedFrameRate: self.activeFrameRate(for: self.wideDevice, settings: self.recorderSettings.wide)
                )
                self.wideRecorder?.writeDeviceFormat(self.wideDevice)
            }

            if self.recorderSettings.ultraWide.enabled {
                self.ultraWideRecorder = CameraStreamRecorder(
                    cameraName: "ultrawide",
                    videoURL: self.outDirURL.appendingPathComponent("ultrawide.mp4"),
                    infoURL: self.outDirURL.appendingPathComponent("ultra_info.csv"),
                    includeAudioTrack: self.embedAudioInCameraMP4 && self.recorderSettings.audioEnabled,
                    expectedFrameRate: self.activeFrameRate(for: self.ultraWideDevice, settings: self.recorderSettings.ultraWide)
                )
                self.ultraWideRecorder?.writeDeviceFormat(self.ultraWideDevice)
            }
            self.logRecordingStartStep("camera_recorders", startClock: startClock)

            if self.recorderSettings.audioEnabled {
                self.audioRecorder = AudioStreamRecorder(
                    audioURL: self.outDirURL.appendingPathComponent("audio.m4a"),
                    infoURL: self.outDirURL.appendingPathComponent("audio_info.csv")
                )
            }
            self.logRecordingStartStep("audio_recorder", startClock: startClock)

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

            DispatchQueue.main.async {
                self.startTime = Date()
                self.toggleRecording(val: true)
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

    private func stopRecording() {
        toggleRecording(val: false)
        recordingTimer?.invalidate()
        recordingTimer = nil
        sensorRecorder?.stop()
        sensorRecorder = nil
        stopLocationRecording()
        timeWriteLabel.text = "mp4,csv"

        sessionQueue.async {
            self.resetRecordingStartAlignment()
            let group = DispatchGroup()
            if let wideRecorder = self.wideRecorder {
                group.enter()
                wideRecorder.finish { group.leave() }
            }
            if let ultraWideRecorder = self.ultraWideRecorder {
                group.enter()
                ultraWideRecorder.finish { group.leave() }
            }
            if let audioRecorder = self.audioRecorder {
                group.enter()
                audioRecorder.finish { group.leave() }
            }
            group.notify(queue: self.sessionQueue) {
                self.writeCaptureMetaJSON(state: "finished")
                self.wideRecorder = nil
                self.ultraWideRecorder = nil
                self.audioRecorder = nil
                DispatchQueue.main.async {
                    self.updateSize()
                }
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        os_log("Started recording: %@", fileURL.path)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error = error {
            os_log("Finished recording with error %@: %@", type: .error, outputFileURL.path, error.localizedDescription)
        } else {
            os_log("Finished recording: %@", outputFileURL.path)
        }
        DispatchQueue.main.async {
            self.movieOutputDidFinishOneFile()
        }
    }

    private func movieOutputDidFinishOneFile() {
        pendingMovieFinishes -= 1
        guard pendingMovieFinishes <= 0 else { return }
        updateSize()
    }

    private func openCaptureDirectory() {
        var sharedURL = URLComponents(url: getRecDir(), resolvingAgainstBaseURL: false)!
        sharedURL.scheme = "shareddocuments"
        UIApplication.shared.open(sharedURL.url!)
    }

    private func toggleRecording(val: Bool) {
        isRecording = val
        updateRecordButtonAppearance(isRecording: val)
        updateAuxiliaryRailButtons(isRecording: val)
        captureStatusBadges["summary"]?.isHidden = !val
        val ? startRECBlinking() : stopRECBlinking()
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
        [settingsRailButton, filesRailButton].forEach { button in
            button?.isEnabled = !isRecording
            button?.alpha = isRecording ? 0.28 : 1.0
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
        let summaryBadge = makeTransparentHUDLabel(textColor: .systemRed)
        sceneView.addSubview(wideBadge)
        sceneView.addSubview(ultraBadge)
        view.addSubview(summaryBadge)
        cameraStatusBadges["wide"] = wideBadge
        cameraStatusBadges["ultra"] = ultraBadge
        captureStatusBadges["summary"] = summaryBadge
        summaryBadge.isHidden = true
        cameraStatusRows["wide"] = wideBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        cameraStatusRows["ultra"] = ultraBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first
        captureStatusRows["summary"] = summaryBadge.subviewsRecursive().compactMap { $0 as? UILabel }.first

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
        settingsButton.addTarget(self, action: #selector(showSettingsOverlay), for: .touchUpInside)
        railStack.addArrangedSubview(settingsButton)
        settingsRailButton = settingsButton

        let recordButton = makeRailButton(icon: "circle.fill", tint: .white)
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

    private func makeSettingsTabButton(title: String, selected: Bool) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = selected ? UIColor.systemTeal.withAlphaComponent(0.78) : UIColor.white.withAlphaComponent(0.10)
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        return button
    }

    private func addSettingsSectionTitle(to stack: UIStackView, title: String) {
        let label = UILabel()
        label.text = title.uppercased()
        label.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        label.letterSpacing = 1.3
        stack.addArrangedSubview(label)
    }

    private func addSettingsHeader(to stack: UIStackView) {
        let titleLabel = UILabel()
        titleLabel.text = "SETTINGS"
        titleLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white

        let detailLabel = UILabel()
        detailLabel.text = "Higher resolutions appear automatically when only one camera is enabled."
        detailLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        detailLabel.numberOfLines = 2

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
    }

    private func addSettingsMenuRow(
        to stack: UIStackView,
        key: String,
        title: String,
        items: [String],
        selectedValue: String,
        compact: Bool = false
    ) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = compact ? 10 : 16

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: compact ? 15 : 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.widthAnchor.constraint(equalToConstant: compact ? 112 : 126).isActive = true

        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .leading
        button.accessibilityValue = resolvedSelectedValue(in: items, preferred: selectedValue)
        button.configuration = settingsMenuConfiguration(title: button.accessibilityValue ?? selectedValue, compact: compact)
        button.menu = UIMenu(children: items.map { item in
            UIAction(title: item, state: item == button.accessibilityValue ? .on : .off) { [weak self, weak button] _ in
                button?.accessibilityValue = item
                button?.configuration = self?.settingsMenuConfiguration(title: item, compact: compact)
            }
        })
        button.showsMenuAsPrimaryAction = true
        settingsMenuButtons[key] = button

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(button)
        stack.addArrangedSubview(row)
    }

    private func updateSettingsMenu(key: String, items: [String], compact: Bool = false) {
        guard let button = settingsMenuButtons[key] else { return }
        let selectedValue = resolvedSelectedValue(in: items, preferred: button.accessibilityValue ?? "")
        button.accessibilityValue = selectedValue
        button.configuration = settingsMenuConfiguration(title: selectedValue, compact: compact)
        button.menu = UIMenu(children: items.map { item in
            UIAction(title: item, state: item == selectedValue ? .on : .off) { [weak self, weak button] _ in
                button?.accessibilityValue = item
                button?.configuration = self?.settingsMenuConfiguration(title: item, compact: compact)
            }
        })
    }

    private func addCameraSettingsSection(
        to stack: UIStackView,
        title: String,
        keyPrefix: String,
        settings: CameraCaptureSettings,
        resolutionItems: [String]
    ) {
        addSettingsSubsectionTitle(to: stack, title: title, switchKey: "\(keyPrefix).enabled", isOn: settings.enabled)
        let compactStack = UIStackView()
        compactStack.axis = .vertical
        compactStack.spacing = 6
        compactStack.layoutMargins = UIEdgeInsets(top: 0, left: 18, bottom: 2, right: 0)
        compactStack.isLayoutMarginsRelativeArrangement = true
        stack.addArrangedSubview(compactStack)
        cameraSettingsGroups[keyPrefix] = compactStack
        addSettingsMenuRow(
            to: compactStack,
            key: "\(keyPrefix).resolution",
            title: "Resolution",
            items: resolutionItems,
            selectedValue: settings.resolution,
            compact: true
        )
        addSettingsMenuRow(
            to: compactStack,
            key: "\(keyPrefix).frameRate",
            title: "Hz",
            items: ["1", "5", "10", "20", "30", "60"],
            selectedValue: settings.frameRate,
            compact: true
        )
        addSettingsRow(
            to: compactStack,
            key: "\(keyPrefix).autoFocus",
            title: "Auto Focus",
            detail: "",
            isOn: settings.autoFocus,
            compact: true
        )
        updateCameraSettingsGroup(keyPrefix: keyPrefix, enabled: settings.enabled)
    }

    private func addSettingsSubsectionTitle(to stack: UIStackView, title: String, switchKey: String? = nil, isOn: Bool = true) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        label.textColor = .white
        row.addArrangedSubview(label)

        if let switchKey {
            let cameraSwitch = UISwitch()
            cameraSwitch.isOn = isOn
            cameraSwitch.onTintColor = .systemTeal
            cameraSwitch.accessibilityIdentifier = switchKey
            cameraSwitch.addTarget(self, action: #selector(cameraEnabledSwitchChanged(_:)), for: .valueChanged)
            settingsSwitches[switchKey] = cameraSwitch
            row.addArrangedSubview(cameraSwitch)
        }

        stack.addArrangedSubview(row)
    }

    @objc private func cameraEnabledSwitchChanged(_ sender: UISwitch) {
        guard let switchKey = sender.accessibilityIdentifier,
              let keyPrefix = switchKey.split(separator: ".").first.map(String.init) else {
            return
        }
        updateCameraSettingsGroup(keyPrefix: keyPrefix, enabled: sender.isOn)
        updateCameraResolutionMenus()
    }

    private func updateCameraResolutionMenus() {
        let wideEnabled = settingsSwitches["wide.enabled"]?.isOn ?? recorderSettings.wide.enabled
        let ultraEnabled = settingsSwitches["ultra.enabled"]?.isOn ?? recorderSettings.ultraWide.enabled
        let requiresMultiCamFormat = wideEnabled && ultraEnabled

        updateSettingsMenu(
            key: "wide.resolution",
            items: cameraResolutionOptions(
                for: wideDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                requiresMultiCamFormat: requiresMultiCamFormat
            ),
            compact: true
        )
        updateSettingsMenu(
            key: "ultra.resolution",
            items: cameraResolutionOptions(
                for: ultraWideDevice ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
                requiresMultiCamFormat: requiresMultiCamFormat
            ),
            compact: true
        )
    }

    private func updateCameraSettingsGroup(keyPrefix: String, enabled: Bool) {
        guard let group = cameraSettingsGroups[keyPrefix] else { return }
        group.isUserInteractionEnabled = enabled
        group.alpha = enabled ? 1.0 : 0.34
    }

    private func resolvedSelectedValue(in items: [String], preferred: String) -> String {
        items.contains(preferred) ? preferred : (items.first ?? preferred)
    }

    private func settingsMenuConfiguration(title: String, compact: Bool = false) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: compact ? 13 : 14, weight: .semibold)
            ])
        )
        config.image = UIImage(systemName: "chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.12)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(
            top: compact ? 6 : 8,
            leading: 12,
            bottom: compact ? 6 : 8,
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

    private func makePanelStack(title: String) -> UIStackView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        titleLabel.letterSpacing = 1.4

        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 9
        return stack
    }

    @discardableResult
    private func addStatusRow(
        to stack: UIStackView,
        store: inout [String: UILabel],
        key: String,
        title: String
    ) -> UILabel {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10

        let nameLabel = UILabel()
        nameLabel.text = title
        nameLabel.font = overlayFont
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let valueLabel = UILabel()
        valueLabel.text = "--"
        valueLabel.font = overlayValueFont
        valueLabel.textColor = .white
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.72

        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(row)
        store[key] = valueLabel
        return valueLabel
    }

    private func addDivider(to stack: UIStackView) {
        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(divider)
    }

    @objc private func showSettingsOverlay() {
        guard settingsOverlayView == nil else { return }
        settingsMenuButtons.removeAll()
        settingsSwitches.removeAll()
        cameraSettingsGroups.removeAll()

        let dimView = UIView()
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black
        view.addSubview(dimView)
        settingsOverlayView = dimView

        let configPanel = makeOverlayPanel()
        dimView.addSubview(configPanel)
        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            configPanel.centerXAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.centerXAnchor),
            configPanel.widthAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.widthAnchor, multiplier: 0.74),
            configPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            configPanel.topAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.topAnchor, constant: 18),
            configPanel.bottomAnchor.constraint(equalTo: dimView.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        configPanel.contentView.addSubview(scrollView)

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
        stack.spacing = 10
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: configPanel.contentView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: configPanel.contentView.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: configPanel.contentView.topAnchor, constant: 18),
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

        addSettingsHeader(to: stack)
        addSettingsSectionTitle(to: stack, title: "Camera")
        let requiresMultiCamResolutionOptions = recorderSettings.wide.enabled && recorderSettings.ultraWide.enabled
        addCameraSettingsSection(
            to: stack,
            title: "Wide Camera",
            keyPrefix: "wide",
            settings: recorderSettings.wide,
            resolutionItems: cameraResolutionOptions(
                for: wideDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                requiresMultiCamFormat: requiresMultiCamResolutionOptions
            )
        )
        addCameraSettingsSection(
            to: stack,
            title: "Ultra-wide Camera",
            keyPrefix: "ultra",
            settings: recorderSettings.ultraWide,
            resolutionItems: cameraResolutionOptions(
                for: ultraWideDevice ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
                requiresMultiCamFormat: requiresMultiCamResolutionOptions
            )
        )

        addSettingsSectionTitle(to: stack, title: "Sensors")
        addSettingsRow(to: stack, key: "imu", title: "IMU", detail: "Raw accel + gyro", isOn: recorderSettings.imuEnabled)
        addSettingsRow(to: stack, key: "mag", title: "Magnetometer", detail: "Raw magnetic field", isOn: recorderSettings.magnetometerEnabled)
        addSettingsRow(to: stack, key: "baro", title: "Barometer", detail: "Pressure + relative altitude", isOn: recorderSettings.barometerEnabled)
        addSettingsRow(to: stack, key: "geo", title: "GeoLoc", detail: "CoreLocation fused geographic fixes", isOn: recorderSettings.geoLocationEnabled)
        addSettingsRow(to: stack, key: "motion", title: "Device Motion", detail: "Fused attitude + gravity", isOn: recorderSettings.deviceMotionEnabled)
        addSettingsRow(to: stack, key: "audio", title: "Audio", detail: "M4A AAC, device input channels", isOn: recorderSettings.audioEnabled)

        addSettingsSectionTitle(to: stack, title: "Storage")
        addSettingsMenuRow(
            to: stack,
            key: "storageFormat",
            title: "Save Format",
            items: ["CSV", "MCAP"],
            selectedValue: recorderSettings.storageFormat
        )
        addSettingsActionButtons(to: actionBar)
    }

    private func addSettingsRow(
        to stack: UIStackView,
        key: String,
        title: String,
        detail: String,
        isOn: Bool,
        compact: Bool = false
    ) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = compact ? 10 : 16

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = compact ? 0 : 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: compact ? 14 : 17, weight: .semibold)
        titleLabel.textColor = .white

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = UIFont.monospacedSystemFont(ofSize: compact ? 10 : 12, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.56)
        detailLabel.isHidden = detail.isEmpty

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        let sensorSwitch = UISwitch()
        sensorSwitch.isOn = isOn
        sensorSwitch.onTintColor = .systemTeal
        settingsSwitches[key] = sensorSwitch

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(sensorSwitch)
        stack.addArrangedSubview(row)
    }

    private func addSettingsActionButtons(to stack: UIStackView) {
        let closeButton = UIButton(type: .system)
        var closeConfig = UIButton.Configuration.filled()
        closeConfig.title = "Close"
        closeConfig.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
        closeConfig.baseForegroundColor = .white
        closeConfig.cornerStyle = .large
        closeButton.configuration = closeConfig
        closeButton.addTarget(self, action: #selector(hideSettingsOverlay), for: .touchUpInside)

        let saveButton = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Save Settings"
        config.baseBackgroundColor = .systemTeal
        config.baseForegroundColor = .black
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        saveButton.configuration = config
        saveButton.addTarget(self, action: #selector(saveSettingsOverlay), for: .touchUpInside)
        stack.addArrangedSubview(closeButton)
        stack.addArrangedSubview(saveButton)
    }

    @objc private func saveSettingsOverlay() {
        recorderSettings = RecorderSettings(
            wide: CameraCaptureSettings(
                enabled: settingsSwitches["wide.enabled"]?.isOn ?? recorderSettings.wide.enabled,
                resolution: selectedSettingsValue(for: "wide.resolution", fallback: recorderSettings.wide.resolution),
                frameRate: selectedSettingsValue(for: "wide.frameRate", fallback: recorderSettings.wide.frameRate),
                autoFocus: settingsSwitches["wide.autoFocus"]?.isOn ?? recorderSettings.wide.autoFocus
            ),
            ultraWide: CameraCaptureSettings(
                enabled: settingsSwitches["ultra.enabled"]?.isOn ?? recorderSettings.ultraWide.enabled,
                resolution: selectedSettingsValue(for: "ultra.resolution", fallback: recorderSettings.ultraWide.resolution),
                frameRate: selectedSettingsValue(for: "ultra.frameRate", fallback: recorderSettings.ultraWide.frameRate),
                autoFocus: settingsSwitches["ultra.autoFocus"]?.isOn ?? recorderSettings.ultraWide.autoFocus
            ),
            imuEnabled: settingsSwitches["imu"]?.isOn ?? recorderSettings.imuEnabled,
            magnetometerEnabled: settingsSwitches["mag"]?.isOn ?? recorderSettings.magnetometerEnabled,
            barometerEnabled: settingsSwitches["baro"]?.isOn ?? recorderSettings.barometerEnabled,
            geoLocationEnabled: settingsSwitches["geo"]?.isOn ?? recorderSettings.geoLocationEnabled,
            deviceMotionEnabled: settingsSwitches["motion"]?.isOn ?? recorderSettings.deviceMotionEnabled,
            audioEnabled: settingsSwitches["audio"]?.isOn ?? recorderSettings.audioEnabled,
            storageFormat: selectedSettingsValue(for: "storageFormat", fallback: recorderSettings.storageFormat)
        )
        recorderSettings.save()
        setStatus("Settings saved")
        hideSettingsOverlay()
        resetPreviewSessionForSettingsChange()
    }

    private func resetPreviewSessionForSettingsChange() {
        startStopButton.isEnabled = false
        sessionQueue.async {
            if self.observesSessionRuntimeErrors {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .AVCaptureSessionRuntimeError,
                    object: self.session
                )
                self.observesSessionRuntimeErrors = false
            }
            self.session.stopRunning()
            self.session = AVCaptureMultiCamSession()
            self.isConfigured = false
            self.isRecordingConfigured = false
            self.wideVideoPort = nil
            self.ultraWideVideoPort = nil
            self.wideDevice = nil
            self.ultraWideDevice = nil
            self.widePreviewOutput = nil
            self.ultraWidePreviewOutput = nil
            self.audioOutput = nil
            self.wideFrameCount = 0
            self.ultraWideFrameCount = 0

            DispatchQueue.main.async {
                self.wideDisplayLayer?.removeFromSuperlayer()
                self.ultraWideDisplayLayer?.removeFromSuperlayer()
                self.wideDisplayLayer = nil
                self.ultraWideDisplayLayer = nil
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

    @objc private func hideSettingsOverlay() {
        settingsOverlayView?.removeFromSuperview()
        settingsOverlayView = nil
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
        var elapsed = Int64(round(Date().timeIntervalSince(startTime)))
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

    private func refreshOverlayStatus() {
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

        let sensorRows = sensorRecorder?.statusRows() ?? [:]
        updateSensorPill(key: "imu", title: "IMU", value: sensorRows["imu"] ?? "0Hz")
        updateSensorPill(key: "mag", title: "Mag", value: sensorRows["mag"] ?? "0Hz")
        updateSensorPill(key: "baro", title: "Baro", value: sensorRows["baro"] ?? "0Hz")
        updateSensorPill(key: "geo", title: "GeoLoc", value: locationRecorder?.statusValue() ?? "0Hz")
        updateSensorPill(key: "motion", title: "Motion", value: sensorRows["motion"] ?? "0Hz")
        updateSensorPill(key: "audio", title: "Audio", value: audioRecorder?.statusValue() ?? "0Hz")

        captureStatusRows["duration"]?.text = isRecording ? (timeLabel.text ?? "00:00:00") : "00:00:00"
        captureStatusRows["size"]?.text = fileSizeLabel.text ?? "? / ?"
        captureStatusRows["mode"]?.text = isRecording ? "Recording" : "Preview"
        captureStatusRows["write"]?.text = isRecording ? recordingDataStatusText() : "mp4 + csv + m4a"
        updateCaptureSummaryLabel()
    }

    private func cameraStatusText(frameCount: Int, device: AVCaptureDevice?, fallbackName: String, settings: CameraCaptureSettings) -> String {
        let resolution: String
        if let device = device {
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            resolution = "\(dimensions.width)x\(dimensions.height)"
        } else {
            resolution = settings.resolution
        }

        let cameraName = fallbackName.hasPrefix("wide") ? "WIDE" : "ULTRAWIDE"
        let hz = frameCount == 0 ? "0 Hz" : String(format: "%.0f Hz", activeFrameRate(for: device, settings: settings))
        return "\(cameraName) \(aspectLabel(for: resolution)) | \(resolution) | \(hz)"
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
        let pixels = Int(size.width * size.height)
        return size.width > 3840 || size.height > 2160 || pixels > 3840 * 2160 ? "hevc" : "h264"
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
        return "\(sensorStatus) \(locationStatus) \(audioStatus)"
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
            guard self.presentedViewController == nil else { return }
            let fileAlert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            fileAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            self.present(fileAlert, animated: true, completion: nil)
        }
    }

    private func showPermissionSettingsAlert(title: String, message: String) {
        DispatchQueue.main.async {
            guard self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            })
            self.present(alert, animated: true, completion: nil)
        }
    }

    private func createFiles() -> Bool {
        let recDirURL = getRecDir()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let date = dateFormatter.string(from: Date())
        outDirURL = recDirURL.appendingPathComponent("SR_\(date)")
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
            "wide": cameraSettingsJSON(recorderSettings.wide),
            "ultrawide": cameraSettingsJSON(recorderSettings.ultraWide),
            "imu_enabled": recorderSettings.imuEnabled,
            "magnetometer_enabled": recorderSettings.magnetometerEnabled,
            "barometer_enabled": recorderSettings.barometerEnabled,
            "geo_location_enabled": recorderSettings.geoLocationEnabled,
            "device_motion_enabled": recorderSettings.deviceMotionEnabled,
            "audio_enabled": recorderSettings.audioEnabled,
            "storage_format": recorderSettings.storageFormat
        ]
    }

    private func cameraSettingsJSON(_ settings: CameraCaptureSettings) -> [String: Any] {
        return [
            "enabled": settings.enabled,
            "resolution": settings.resolution,
            "frame_rate": clampedFrameRate(from: settings.frameRate),
            "auto_focus": settings.autoFocus
        ]
    }

    private func recordingStartJSON() -> [String: Any] {
        let wideRequestedFPS = clampedFrameRate(from: recorderSettings.wide.frameRate)
        let ultraRequestedFPS = clampedFrameRate(from: recorderSettings.ultraWide.frameRate)
        let wideActiveFPS = activeFrameRate(for: wideDevice, settings: recorderSettings.wide)
        let ultraActiveFPS = activeFrameRate(for: ultraWideDevice, settings: recorderSettings.ultraWide)
        return [
            "sync_first_frame": shouldSynchronizeRecordingStart(),
            "sync_rule": "Only synchronize the first camera frames when both cameras are enabled and requested/active FPS are nearly equal.",
            "wide_requested_fps": wideRequestedFPS,
            "wide_active_fps": wideActiveFPS,
            "ultrawide_requested_fps": ultraRequestedFPS,
            "ultrawide_active_fps": ultraActiveFPS
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
            "time_model": [
                "sensor_sec": "monotonic host clock seconds; same time base used by AVFoundation capture timestamps after conversion, CoreMotion timestamps, and derived geo_location timestamps",
                "utc_sec": "Unix UTC seconds",
                "utc_minus_sensor_offset_sec": utcMinusSensorOffsetSec,
                "alignment": "Use sensor_sec for sensor fusion. Use utc_sec for wall-clock/GNSS-style correlation."
            ],
            "streams": [
                "wide_camera": [
                    "enabled": recorderSettings.wide.enabled,
                    "media_file": "wide.mp4",
                    "index_file": "wide_info.csv",
                    "codec": videoCodecName(for: recorderSettings.wide),
                    "nominal_fps": activeFrameRate(for: wideDevice, settings: recorderSettings.wide),
                    "requested_resolution": recorderSettings.wide.resolution,
                    "auto_focus": recorderSettings.wide.autoFocus,
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"]
                ],
                "ultrawide_camera": [
                    "enabled": recorderSettings.ultraWide.enabled,
                    "media_file": "ultrawide.mp4",
                    "index_file": "ultra_info.csv",
                    "codec": videoCodecName(for: recorderSettings.ultraWide),
                    "nominal_fps": activeFrameRate(for: ultraWideDevice, settings: recorderSettings.ultraWide),
                    "requested_resolution": recorderSettings.ultraWide.resolution,
                    "auto_focus": recorderSettings.ultraWide.autoFocus,
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width_px", "height_px", "fx_px", "fy_px", "cx_px", "cy_px"]
                ],
                "audio": [
                    "enabled": recorderSettings.audioEnabled,
                    "media_file": "audio.m4a",
                    "index_file": "audio_info.csv",
                    "embedded_in": embedAudioInCameraMP4 ? ["wide.mp4", "ultrawide.mp4"] : [],
                    "codec": "aac",
                    "container": "m4a",
                    "requested_channels": 2,
                    "channel_count_source": "actual channel count is written per buffer in audio_info.csv",
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "duration_sec", "sample_count", "sample_rate_hz", "channels"]
                ],
                "accelerometer": [
                    "enabled": recorderSettings.imuEnabled,
                    "file": "accelerometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "ax_m_s2", "ay_m_s2", "az_m_s2"],
                    "source_unit": "CoreMotion g",
                    "acceleration_conversion": "CoreMotion g converted to m/s^2 using 9.80665"
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
                    "acceleration_conversion": "CoreMotion g converted to m/s^2 using 9.80665"
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

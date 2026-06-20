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

private final class CameraStreamRecorder {
    private let videoURL: URL
    private let infoURL: URL
    private let cameraName: String
    private let includeAudioTrack: Bool
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var infoHandle: FileHandle?
    private var firstPTS: CMTime?
    private let utcMinusSensorOffsetSec: TimeInterval
    private var frameIndex = 0
    private var isFinishing = false

    init(cameraName: String, videoURL: URL, infoURL: URL, includeAudioTrack: Bool) {
        self.cameraName = cameraName
        self.videoURL = videoURL
        self.infoURL = infoURL
        self.includeAudioTrack = includeAudioTrack
        self.utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: infoURL)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("frame_index,sensor_sec,utc_sec,exposure_sec,iso,width,height,fx,fy,cx,cy")
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
        writeInfoLine("# active_format,\(dimensions.width)x\(dimensions.height),fps,30")
    }

    private func configureWriter(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        do {
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(width * height * 4, 2_000_000),
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
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
            writeInfoLine("# \(cameraName),video,\(width)x\(height)")
        } catch {
            writeInfoLine("# writer_init_failed \(error.localizedDescription)")
        }
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

    init(audioURL: URL, infoURL: URL) {
        self.audioURL = audioURL
        self.infoURL = infoURL
        utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: infoURL)
        FileManager.default.createFile(atPath: infoURL.path, contents: nil)
        infoHandle = try? FileHandle(forWritingTo: infoURL)
        writeInfoLine("frame_index,sensor_sec,utc_sec,duration_sec,sample_count,sample_rate,channels")
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
        guard let first = firstSensorSec, let latest = latestSensorSec, latest > first, frameIndex > 1 else {
            return "AUD \(frameIndex)"
        }
        let hz = Double(frameIndex - 1) / (latest - first)
        return String(format: "AUD %.0fHz", hz)
    }

    func statusValue() -> String {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard frameIndex > 0 else { return "0Hz" }
        guard let first = firstSensorSec, let latest = latestSensorSec, latest > first, frameIndex > 1 else {
            return "\(frameIndex)"
        }
        let hz = Double(frameIndex - 1) / (latest - first)
        return String(format: "%.0fHz", hz)
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
        queue.name = "com.scantoolscapture.sensors"
        queue.maxConcurrentOperationCount = 1
        utcMinusSensorOffsetSec = Date().timeIntervalSince1970 - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func start(in directory: URL) {
        accelerometerWriter = SensorCSVWriter(
            url: directory.appendingPathComponent("accelerometer.csv"),
            header: "sensor_sec,utc_sec,ax,ay,az"
        )
        gyroscopeWriter = SensorCSVWriter(
            url: directory.appendingPathComponent("gyroscope.csv"),
            header: "sensor_sec,utc_sec,gx,gy,gz"
        )
        imuWriter = SensorCSVWriter(
            url: directory.appendingPathComponent("imu.csv"),
            header: "sensor_sec,utc_sec,ax,ay,az,gx,gy,gz,accel_sensor_sec,gyro_sensor_sec"
        )
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
                "gravity_x",
                "gravity_y",
                "gravity_z",
                "user_accel_x",
                "user_accel_y",
                "user_accel_z",
                "rotation_rate_x",
                "rotation_rate_y",
                "rotation_rate_z",
                "magnetic_field_x",
                "magnetic_field_y",
                "magnetic_field_z",
                "magnetic_accuracy",
                "heading_deg"
            ].joined(separator: ",")
        )
        magnetometerWriter = SensorCSVWriter(
            url: directory.appendingPathComponent("magnetometer.csv"),
            header: "sensor_sec,utc_sec,mx,my,mz"
        )
        barometerWriter = SensorCSVWriter(
            url: directory.appendingPathComponent("barometer.csv"),
            header: "sensor_sec,utc_sec,pressure_kpa,relative_altitude_m"
        )

        startIMUUpdates()
        startDeviceMotionUpdates()
        startMagnetometerUpdates()
        startBarometerUpdates()
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
            self.recordAccelerometerSample(sensorSec)
            self.latestAccelerometerSample = AccelerometerSample(
                sensorSec: sensorSec,
                utcSec: utcSec,
                x: data.acceleration.x,
                y: data.acceleration.y,
                z: data.acceleration.z
            )
            self.accelerometerWriter?.writeLine(String(
                format: "%.9f,%.9f,%.9f,%.9f,%.9f",
                sensorSec, utcSec, data.acceleration.x, data.acceleration.y, data.acceleration.z
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
                data.gravity.x,
                data.gravity.y,
                data.gravity.z,
                data.userAcceleration.x,
                data.userAcceleration.y,
                data.userAcceleration.z,
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
                "horizontal_accuracy",
                "vertical_accuracy",
                "speed",
                "speed_accuracy",
                "course",
                "course_accuracy",
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
    private var cameraStatusRows: [String: UILabel] = [:]
    private var sensorStatusRows: [String: UILabel] = [:]
    private var captureStatusRows: [String: UILabel] = [:]
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
    private let sessionQueue = DispatchQueue(label: "com.scantoolscapture.multicam")

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
    private let recordingStartToleranceSec: TimeInterval = 1.0 / 60.0
    private let embedAudioInCameraMP4 = false
    private let previewOnlyMode = false
    private let previewDebugMode: PreviewDebugMode = .dual
    private var observesSessionRuntimeErrors = false
    private var pendingMovieFinishes = 0

    private var outDirURL: URL!
    private var startDebugURL: URL?
    private var diskCapacity: String = "?"
    private var startTime: Date!
    private var recordingTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        updateDiskCapacity()
        installLandscapeOverlay()
        initializeUI()
        startStopButton.setTitle("Start", for: .normal)
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
        setStatus("Camera permission")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    self.showError(msg: "Camera permission is required for capture.")
                }
                completion(granted)
            }
        default:
            showError(msg: "Camera permission is required for capture.")
            completion(false)
        }
    }

    private func requestAudioAccess(_ completion: @escaping (Bool) -> Void) {
        setStatus("Audio permission")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    os_log("Microphone permission was not granted.", type: .error)
                }
                completion(granted)
            }
        default:
            os_log("Microphone permission is unavailable.", type: .error)
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
        guard CLLocationManager.locationServicesEnabled() else {
            return
        }

        locationRecorder = GeoLocationStreamRecorder(directory: outDirURL)
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationRecorder?.close()
            locationRecorder = nil
        @unknown default:
            locationRecorder?.close()
            locationRecorder = nil
        }
    }

    private func stopLocationRecording() {
        locationManager.stopUpdatingLocation()
        locationRecorder?.close()
        locationRecorder = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
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
        requestCameraAccess { granted in
            guard granted else { return }
            self.requestAudioAccess { audioGranted in
                if self.previewDebugMode == .wideOnly {
                    self.configureSingleCameraPreview()
                    return
                }

                self.sessionQueue.async {
                    self.configurePreviewSession(includeAudio: audioGranted)
                    guard self.isConfigured else { return }
                    self.session.startRunning()
                    DispatchQueue.main.async {
                        self.startStopButton.isEnabled = true
                    }
                    self.setStatus(self.session.isRunning ? "Ready" : "Not running")
                }
            }
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
                self.sceneView.layer.addSublayer(diagnosticLayer)
                self.diagnosticLayer = diagnosticLayer

                let previewView = CameraPreviewView(frame: self.sceneView.bounds)
                previewView.backgroundColor = UIColor.systemBlue
                previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                previewView.previewLayer.session = previewSession
                previewView.previewLayer.videoGravity = .resizeAspectFill
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
        guard previewDebugMode == .dual else {
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

        if previewDebugMode == .wideOnly || previewDebugMode == .dual {
            guard configurePreviewCamera(
                deviceType: .builtInWideAngleCamera,
                cameraName: "wide",
                previewIndex: 0
            ) else {
                os_log("Failed to configure wide camera.", type: .error)
                showError(msg: "Failed to configure wide camera.")
                return
            }
        }

        if previewDebugMode == .ultraWideOnly || previewDebugMode == .dual {
            guard configurePreviewCamera(
                deviceType: .builtInUltraWideCamera,
                cameraName: "ultrawide",
                previewIndex: 1
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
        previewIndex: Int
    ) -> Bool {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
            os_log("Camera unavailable: %@", type: .error, deviceType.rawValue)
            return false
        }

        do {
            try configureDeviceForPreview(device)
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
                self.sceneView.layer.addSublayer(displayLayer)
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
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = (cameraName == "wide" ? UIColor.systemBlue : UIColor.systemOrange).cgColor
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
        previewView.backgroundColor = cameraName == "wide" ? UIColor.systemBlue : UIColor.systemOrange
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.previewLayer.videoGravity = .resizeAspectFill
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

    private func configureDeviceForPreview(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if let format = preferred1080pFormats(for: device).first {
            device.activeFormat = format
        }

        let duration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func preferred1080pFormats(for device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        let targetWidth = 1920
        let targetHeight = 1080
        let targetArea = targetWidth * targetHeight

        return device.formats.filter { format in
            guard format.isMultiCamSupported else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= 30 && 30 <= range.maxFrameRate
            }
        }.sorted { lhs, rhs in
            let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsArea = Int(lhsDims.width) * Int(lhsDims.height)
            let rhsArea = Int(rhsDims.width) * Int(rhsDims.height)

            let lhsExact1080p = Int(lhsDims.width) == targetWidth && Int(lhsDims.height) == targetHeight
            let rhsExact1080p = Int(rhsDims.width) == targetWidth && Int(rhsDims.height) == targetHeight
            if lhsExact1080p != rhsExact1080p {
                return lhsExact1080p
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
        let formats = preferred1080pFormats(for: device)
        guard let currentIndex = formats.firstIndex(where: { $0 === device.activeFormat }),
              currentIndex + 1 < formats.count else {
            return false
        }

        let nextFormat = formats[currentIndex + 1]
        do {
            try device.lockForConfiguration()
            device.activeFormat = nextFormat
            let duration = CMTime(value: 1, timescale: 30)
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

    private func configureVideoConnection(_ connection: AVCaptureConnection) {
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

        if previewDebugMode != .dual {
            layoutSampleBufferDisplayLayer(wideDisplayLayer, in: bounds)
            layoutSampleBufferDisplayLayer(ultraWideDisplayLayer, in: bounds)
            wideCameraPreviewView?.frame = bounds
            ultraWideCameraPreviewView?.frame = bounds
            widePreviewLayer?.frame = wideCameraPreviewView?.bounds ?? bounds
            ultraWidePreviewLayer?.frame = ultraWideCameraPreviewView?.bounds ?? bounds
            return
        }

        let halfWidth = bounds.width / 2
        layoutSampleBufferDisplayLayer(wideDisplayLayer, in: CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height))
        layoutSampleBufferDisplayLayer(ultraWideDisplayLayer, in: CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height))
        wideCameraPreviewView?.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        ultraWideCameraPreviewView?.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)
        widePreviewLayer?.frame = wideCameraPreviewView?.bounds ?? .zero
        ultraWidePreviewLayer?.frame = ultraWideCameraPreviewView?.bounds ?? .zero
    }

    private func layoutSampleBufferDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer?, in frame: CGRect) {
        guard let displayLayer = displayLayer else { return }
        displayLayer.bounds = CGRect(x: 0, y: 0, width: frame.height, height: frame.width)
        displayLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
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
            self.timeLabel.text = status
            self.frameCounterLabel.text = "\(self.previewDebugMode.rawValue), \(running), W \(self.wideFrameCount), U \(self.ultraWideFrameCount), S \(self.singleFrameCount), \(Int(frame.width))x\(Int(frame.height))"
            self.refreshOverlayStatus()
        }
    }

    private func startRecording() {
        startStopButton.isEnabled = false
        timeLabel.text = "Preparing"
        appendStartDebug("start_tapped")

        guard isConfigured && session.isRunning else {
            startStopButton.isEnabled = true
            appendStartDebug("start_failed_preview_not_ready")
            showError(msg: "Camera preview is not ready yet.")
            return
        }

        guard createFiles() else {
            startStopButton.isEnabled = true
            showError(msg: "Failed to create the recording directory.")
            return
        }

        sessionQueue.async {
            self.appendStartDebug("session_queue_enter")
            self.resetRecordingStartAlignment()
            self.appendStartDebug("create_wide_recorder_begin")
            self.wideRecorder = CameraStreamRecorder(
                cameraName: "wide",
                videoURL: self.outDirURL.appendingPathComponent("wide.mp4"),
                infoURL: self.outDirURL.appendingPathComponent("wide_info.csv"),
                includeAudioTrack: self.embedAudioInCameraMP4
            )
            self.wideRecorder?.writeDeviceFormat(self.wideDevice)
            self.appendStartDebug("create_wide_recorder_done")
            self.appendStartDebug("create_ultrawide_recorder_begin")
            self.ultraWideRecorder = CameraStreamRecorder(
                cameraName: "ultrawide",
                videoURL: self.outDirURL.appendingPathComponent("ultrawide.mp4"),
                infoURL: self.outDirURL.appendingPathComponent("ultra_info.csv"),
                includeAudioTrack: self.embedAudioInCameraMP4
            )
            self.ultraWideRecorder?.writeDeviceFormat(self.ultraWideDevice)
            self.appendStartDebug("create_ultrawide_recorder_done")
            self.appendStartDebug("create_audio_recorder_begin")
            self.audioRecorder = AudioStreamRecorder(
                audioURL: self.outDirURL.appendingPathComponent("audio.m4a"),
                infoURL: self.outDirURL.appendingPathComponent("audio_info.csv")
            )
            self.appendStartDebug("create_audio_recorder_done")
            self.appendStartDebug("start_sensor_recorder_begin")
            let sensorRecorder = SensorStreamRecorder()
            sensorRecorder.start(in: self.outDirURL)
            self.sensorRecorder = sensorRecorder
            self.appendStartDebug("start_sensor_recorder_done")

            DispatchQueue.main.async {
                self.appendStartDebug("main_recording_begin")
                self.startTime = Date()
                self.toggleRecording(val: true)
                self.appendStartDebug("start_location_begin")
                self.startLocationRecording()
                self.appendStartDebug("start_location_done")
                self.updateTime()
                self.recordingTimer = Timer.scheduledTimer(
                    timeInterval: 1.0,
                    target: self,
                    selector: #selector(self.updateTime),
                    userInfo: nil,
                    repeats: true
                )
                self.startStopButton.isEnabled = true
                self.appendStartDebug("start_recording_done")
            }
        }
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
                    self.openCaptureDirectory()
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
        openCaptureDirectory()
    }

    private func openCaptureDirectory() {
        var sharedURL = URLComponents(url: outDirURL, resolvingAgainstBaseURL: false)!
        sharedURL.scheme = "shareddocuments"
        UIApplication.shared.open(sharedURL.url!)
    }

    private func toggleRecording(val: Bool) {
        isRecording = val
        if val {
            startStopButton.setTitle("Stop", for: .normal)
            fpsStepper.isEnabled = false
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            startStopButton.setTitle("Start", for: .normal)
            fpsStepper.isEnabled = true
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @IBAction func fpsStepperChanged(_ sender: UIStepper) {
        fpsStepper.value = 30
        fpsLabel.text = "30.0 FPS"
    }

    private func installLandscapeOverlay() {
        legacyControlPanel = startStopButton.superview
        legacyControlPanel?.isHidden = true

        let leftPanel = makeOverlayPanel()
        let rightPanel = makeOverlayPanel()
        view.addSubview(leftPanel)
        view.addSubview(rightPanel)

        NSLayoutConstraint.activate([
            leftPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            leftPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            leftPanel.widthAnchor.constraint(equalToConstant: 270),
            leftPanel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),

            rightPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            rightPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            rightPanel.widthAnchor.constraint(equalToConstant: 270),
            rightPanel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14)
        ])

        let sensorStack = makePanelStack(title: "SENSOR STREAMS")
        leftPanel.contentView.addSubview(sensorStack)
        NSLayoutConstraint.activate([
            sensorStack.leadingAnchor.constraint(equalTo: leftPanel.contentView.leadingAnchor, constant: 14),
            sensorStack.trailingAnchor.constraint(equalTo: leftPanel.contentView.trailingAnchor, constant: -14),
            sensorStack.topAnchor.constraint(equalTo: leftPanel.contentView.topAnchor, constant: 14),
            sensorStack.bottomAnchor.constraint(equalTo: leftPanel.contentView.bottomAnchor, constant: -14)
        ])

        addStatusRow(to: sensorStack, store: &cameraStatusRows, key: "wide", title: "Wide")
        addStatusRow(to: sensorStack, store: &cameraStatusRows, key: "ultra", title: "Ultra")
        addDivider(to: sensorStack)
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "imu", title: "IMU")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "accel", title: "Accel")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "gyro", title: "Gyro")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "mag", title: "Mag")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "baro", title: "Baro")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "motion", title: "Motion")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "geo", title: "Geo")
        addStatusRow(to: sensorStack, store: &sensorStatusRows, key: "audio", title: "Audio")

        let controlStack = makePanelStack(title: "CAPTURE")
        rightPanel.contentView.addSubview(controlStack)
        NSLayoutConstraint.activate([
            controlStack.leadingAnchor.constraint(equalTo: rightPanel.contentView.leadingAnchor, constant: 14),
            controlStack.trailingAnchor.constraint(equalTo: rightPanel.contentView.trailingAnchor, constant: -14),
            controlStack.topAnchor.constraint(equalTo: rightPanel.contentView.topAnchor, constant: 14),
            controlStack.bottomAnchor.constraint(equalTo: rightPanel.contentView.bottomAnchor, constant: -14)
        ])

        let recordButton = UIButton(type: .system)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.setTitle("Start", for: .normal)
        recordButton.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        recordButton.tintColor = .black
        recordButton.backgroundColor = UIColor.systemGreen
        recordButton.layer.cornerRadius = 18
        recordButton.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        recordButton.addTarget(self, action: #selector(startStopButtonPressed(_:)), for: .touchUpInside)
        controlStack.addArrangedSubview(recordButton)
        startStopButton = recordButton

        let settingsButton = UIButton(type: .system)
        settingsButton.setTitle("Settings", for: .normal)
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        settingsButton.tintColor = .white
        settingsButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        settingsButton.layer.cornerRadius = 14
        settingsButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        settingsButton.addTarget(self, action: #selector(showSettingsOverlay), for: .touchUpInside)
        controlStack.addArrangedSubview(settingsButton)

        addDivider(to: controlStack)
        let durationLabel = addStatusRow(to: controlStack, store: &captureStatusRows, key: "duration", title: "Duration")
        let sizeLabel = addStatusRow(to: controlStack, store: &captureStatusRows, key: "size", title: "Size")
        let modeLabel = addStatusRow(to: controlStack, store: &captureStatusRows, key: "mode", title: "Mode")
        let writeLabel = addStatusRow(to: controlStack, store: &captureStatusRows, key: "write", title: "Write")

        timeLabel = durationLabel
        fileSizeLabel = sizeLabel
        frameCounterLabel = modeLabel
        timeWriteLabel = writeLabel
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

        let dimView = UIView()
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        view.addSubview(dimView)
        settingsOverlayView = dimView

        let panel = makeOverlayPanel()
        dimView.addSubview(panel)
        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panel.centerXAnchor.constraint(equalTo: dimView.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: dimView.centerYAnchor),
            panel.widthAnchor.constraint(equalTo: dimView.widthAnchor, multiplier: 0.74),
            panel.heightAnchor.constraint(equalTo: dimView.heightAnchor, multiplier: 0.82)
        ])

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        panel.contentView.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        let stack = makePanelStack(title: "SETTINGS")
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        addSettingsRow(to: stack, title: "Wide camera", detail: "1920x1080 / 30Hz", isOn: true)
        addSettingsRow(to: stack, title: "Ultra-wide camera", detail: "1920x1080 / 30Hz", isOn: true)
        addSettingsRow(to: stack, title: "Raw IMU", detail: "Accel + gyro, target 400Hz", isOn: true)
        addSettingsRow(to: stack, title: "Device motion", detail: "Fused attitude, target 100Hz", isOn: true)
        addSettingsRow(to: stack, title: "Magnetometer", detail: "Raw magnetic field, target 50Hz", isOn: true)
        addSettingsRow(to: stack, title: "Barometer", detail: "Pressure + relative altitude", isOn: true)
        addSettingsRow(to: stack, title: "Geo location", detail: "CoreLocation geographic fixes", isOn: true)
        addSettingsRow(to: stack, title: "Audio", detail: "M4A AAC, device input channels", isOn: true)

        let hintLabel = UILabel()
        hintLabel.text = "This page is the UI shell. Sensor toggles will be wired into the capture pipeline next."
        hintLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.54)
        hintLabel.numberOfLines = 0
        stack.addArrangedSubview(hintLabel)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        closeButton.tintColor = .black
        closeButton.backgroundColor = UIColor.systemTeal
        closeButton.layer.cornerRadius = 14
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        closeButton.addTarget(self, action: #selector(hideSettingsOverlay), for: .touchUpInside)
        stack.addArrangedSubview(closeButton)
    }

    private func addSettingsRow(to stack: UIStackView, title: String, detail: String, isOn: Bool) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.56)

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        let sensorSwitch = UISwitch()
        sensorSwitch.isOn = isOn
        sensorSwitch.onTintColor = .systemTeal

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(sensorSwitch)
        stack.addArrangedSubview(row)
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
            fallbackName: "wide.mp4"
        )
        cameraStatusRows["ultra"]?.text = cameraStatusText(
            frameCount: ultraWideFrameCount,
            device: ultraWideDevice,
            fallbackName: "ultrawide.mp4"
        )

        let sensorRows = sensorRecorder?.statusRows() ?? [:]
        sensorStatusRows["imu"]?.text = sensorRows["imu"] ?? "0Hz"
        sensorStatusRows["accel"]?.text = sensorRows["accel"] ?? "0Hz"
        sensorStatusRows["gyro"]?.text = sensorRows["gyro"] ?? "0Hz"
        sensorStatusRows["mag"]?.text = sensorRows["mag"] ?? "0Hz"
        sensorStatusRows["baro"]?.text = sensorRows["baro"] ?? "0Hz"
        sensorStatusRows["motion"]?.text = sensorRows["motion"] ?? "0Hz"
        sensorStatusRows["geo"]?.text = locationRecorder?.statusValue() ?? "0Hz"
        sensorStatusRows["audio"]?.text = audioRecorder?.statusValue() ?? "0Hz"

        captureStatusRows["duration"]?.text = isRecording ? (timeLabel.text ?? "00:00:00") : "00:00:00"
        captureStatusRows["size"]?.text = fileSizeLabel.text ?? "? / ?"
        captureStatusRows["mode"]?.text = isRecording ? "Recording" : "Preview"
        captureStatusRows["write"]?.text = isRecording ? recordingDataStatusText() : "mp4 + csv + m4a"
    }

    private func cameraStatusText(frameCount: Int, device: AVCaptureDevice?, fallbackName: String) -> String {
        let resolution: String
        if let device = device {
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            resolution = "\(dimensions.width)x\(dimensions.height)"
        } else {
            resolution = "1920x1080"
        }

        if frameCount == 0 {
            return "0Hz • \(resolution)"
        }
        return "30Hz • \(resolution) • \(frameCount)f"
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
            let fileAlert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            fileAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            self.present(fileAlert, animated: true, completion: nil)
        }
    }

    private func createFiles() -> Bool {
        let recDirURL = getRecDir()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let date = dateFormatter.string(from: Date())
        outDirURL = recDirURL.appendingPathComponent(date)
        startDebugURL = outDirURL.appendingPathComponent("start_debug.txt")
        do {
            try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            os_log("Cannot create the output directory: %@", type: .error, error.localizedDescription)
            return false
        }

        appendStartDebug("recording_directory_created")
        writeCaptureMetaJSON(state: "created")
        appendStartDebug("meta_created")
        updateDiskCapacity()
        return true
    }

    private func appendStartDebug(_ message: String) {
        guard let url = startDebugURL else { return }
        let line = String(format: "%.6f,%@\n", Date().timeIntervalSince1970, message)
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
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
            "created_utc_sec": utcSec,
            "updated_utc_sec": utcSec,
            "time_model": [
                "sensor_sec": "monotonic host clock seconds; same time base used by AVFoundation capture timestamps after conversion, CoreMotion timestamps, and derived geo_location timestamps",
                "utc_sec": "Unix UTC seconds",
                "utc_minus_sensor_offset_sec": utcMinusSensorOffsetSec,
                "alignment": "Use sensor_sec for sensor fusion. Use utc_sec for wall-clock/GNSS-style correlation."
            ],
            "streams": [
                "wide_camera": [
                    "media_file": "wide.mp4",
                    "index_file": "wide_info.csv",
                    "codec": "h264",
                    "nominal_fps": 30,
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width", "height", "fx", "fy", "cx", "cy"]
                ],
                "ultrawide_camera": [
                    "media_file": "ultrawide.mp4",
                    "index_file": "ultra_info.csv",
                    "codec": "h264",
                    "nominal_fps": 30,
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "exposure_sec", "iso", "width", "height", "fx", "fy", "cx", "cy"]
                ],
                "audio": [
                    "media_file": "audio.m4a",
                    "index_file": "audio_info.csv",
                    "embedded_in": embedAudioInCameraMP4 ? ["wide.mp4", "ultrawide.mp4"] : [],
                    "codec": "aac",
                    "container": "m4a",
                    "requested_channels": 2,
                    "channel_count_source": "actual channel count is written per buffer in audio_info.csv",
                    "timestamp_column": "sensor_sec",
                    "utc_column": "utc_sec",
                    "schema": ["frame_index", "sensor_sec", "utc_sec", "duration_sec", "sample_count", "sample_rate", "channels"]
                ],
                "accelerometer": [
                    "file": "accelerometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "ax", "ay", "az"],
                    "units": ["s", "s", "g", "g", "g"]
                ],
                "gyroscope": [
                    "file": "gyroscope.csv",
                    "schema": ["sensor_sec", "utc_sec", "gx", "gy", "gz"],
                    "units": ["s", "s", "rad/s", "rad/s", "rad/s"]
                ],
                "imu": [
                    "file": "imu.csv",
                    "schema": ["sensor_sec", "utc_sec", "ax", "ay", "az", "gx", "gy", "gz", "accel_sensor_sec", "gyro_sensor_sec"],
                    "note": "Rows are keyed by gyro samples with the latest raw accelerometer sample attached."
                ],
                "device_motion": [
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
                        "gravity_x",
                        "gravity_y",
                        "gravity_z",
                        "user_accel_x",
                        "user_accel_y",
                        "user_accel_z",
                        "rotation_rate_x",
                        "rotation_rate_y",
                        "rotation_rate_z",
                        "magnetic_field_x",
                        "magnetic_field_y",
                        "magnetic_field_z",
                        "magnetic_accuracy",
                        "heading_deg"
                    ]
                ],
                "magnetometer": [
                    "file": "magnetometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "mx", "my", "mz"],
                    "units": ["s", "s", "microtesla", "microtesla", "microtesla"]
                ],
                "barometer": [
                    "file": "barometer.csv",
                    "schema": ["sensor_sec", "utc_sec", "pressure_kpa", "relative_altitude_m"]
                ],
                "geo_location": [
                    "file": "geo_location.csv",
                    "source": "CoreLocation fused geographic location, not raw GNSS measurements",
                    "schema": [
                        "sensor_sec",
                        "utc_sec",
                        "latitude",
                        "longitude",
                        "altitude",
                        "horizontal_accuracy",
                        "vertical_accuracy",
                        "speed",
                        "speed_accuracy",
                        "course",
                        "course_accuracy",
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

import Foundation
import AVFoundation
import CoreImage
import ImageIO
import os.log
import Metal
import UIKit
import UniformTypeIdentifiers
import CoreMotion


func timestampToInt(_ timestamp: TimeInterval) -> Int64 {
    return Int64(round(timestamp * 1000000))  // second to microsecond
}


class ImageStreamer {
    var path: URL!
    var isInitialized: Bool = false
    let timeScale: Int32 = Int32(timestampToInt(1.0))  // microseconds
    private var _assetWriter: AVAssetWriter?
    private var _assetWriterInput: AVAssetWriterInput?
    private var _audioInput: AVAssetWriterInput?
    private var _adapter: AVAssetWriterInputPixelBufferAdaptor?
    private let lock = NSLock()
    var counter: Int64 = 0
    
    init?(outDir: URL) {
        path = outDir.appendingPathComponent("images.mp4")
    }

    func initializeStream(buffer: CVPixelBuffer, timestamp: TimeInterval) {
        let writer = try! AVAssetWriter(outputURL: path, fileType: .mp4)
        writer.movieFragmentInterval = CMTimeMake(value: timestampToInt(1.0), timescale: timeScale)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidthOfPlane(buffer, 0),
            AVVideoHeightKey: CVPixelBufferGetHeightOfPlane(buffer, 0),
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.mediaTimeScale = timeScale
        input.expectsMediaDataInRealTime = true
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        if writer.canAdd(input) {
            writer.add(input)
        } else {
            os_log("Cannot initialize image stream", type:.error)
        }
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        } else {
            os_log("Cannot initialize audio stream", type:.error)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: CMTimeMake(value: timestampToInt(timestamp), timescale:timeScale))
        
        _assetWriter = writer
        _assetWriterInput = input
        _audioInput = audioInput
        _adapter = adapter
        isInitialized = true
        counter = 0
    }
    
    func resetStream() {
        isInitialized = false
        _assetWriter = nil
        _assetWriterInput = nil
        _audioInput = nil
        _adapter = nil
    }
    
    func write(buffer: CVPixelBuffer, timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if !isInitialized {
            initializeStream(buffer: buffer, timestamp: timestamp)
        }
        while _assetWriterInput?.isReadyForMoreMediaData == false {
            lock.unlock()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))  // wait 5ms
            lock.lock()
        }
        let time = CMTimeMake(value: timestampToInt(timestamp), timescale: timeScale)
        if !_adapter!.append(buffer, withPresentationTime: time) {
            os_log("Could not append new image %@ to stream: %@ ", type:.error, counter, _assetWriter!.status.rawValue)
        }
        counter += 1
    }

    func writeAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isInitialized, let audioInput = _audioInput else { return }
        if audioInput.isReadyForMoreMediaData == false {
            return
        }
        if !audioInput.append(sampleBuffer) {
            os_log("Could not append audio to stream: %@", type: .error, _assetWriter?.error?.localizedDescription ?? "unknown")
        }
    }
    
    func finish() {
        lock.lock()
        guard let writer = _assetWriter, let videoInput = _assetWriterInput else {
            lock.unlock()
            return
        }
        let audioInput = _audioInput
        os_log("Finishing the image stream, status: %d, ready? %d", writer.status.rawValue, videoInput.isReadyForMoreMediaData ? 1 : 0)
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        lock.unlock()
        writer.finishWriting { [weak self] in
            self?.lock.lock()
            self?.resetStream()
            self?.lock.unlock()
        }
    }
}


class ImageWriter {
    var outDir: URL!
    let imageContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!)
    //    let imageContext = CIContext(options: nil)
    
    init?(outDir: URL) {
        self.outDir = outDir
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            os_log("Cannot create the image directory: %@", type:.error, error.localizedDescription)
            return nil
        }
    }
    
    private func imageBufferToUIImage(buffer: CVPixelBuffer) -> UIImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let cgImage = self.imageContext.createCGImage(ciImage, from: ciImage.extent)
        let image = UIImage(cgImage: cgImage!)
        return image
    }

    func write(buffer: CVPixelBuffer, timestamp: TimeInterval) {
        let image = self.imageBufferToUIImage(buffer: buffer)
        if let data = image.jpegData(compressionQuality: 0.5) {
            let imagePath = outDir.appendingPathComponent(String(format: "%lld.jpg", timestampToInt(timestamp)))
            do {
                try data.write(to: imagePath)
            } catch {
                os_log("Cannot write image: %@", type:.error, error.localizedDescription)
            }
        }
    }
    
    // Apparently slower than using UIImage.jpegData
    func write2(buffer: CVPixelBuffer, timestamp: TimeInterval) {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let cgImage = self.imageContext.createCGImage(ciImage, from: ciImage.extent)
        
        let imagePath = outDir.appendingPathComponent(String(format: "%lld.jpg", timestampToInt(timestamp)))
        let options: NSDictionary = [kCGImageDestinationLossyCompressionQuality: 0.5]
        let myImageDest = CGImageDestinationCreateWithURL(imagePath as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(myImageDest, cgImage!, options)
        CGImageDestinationFinalize(myImageDest)
    }
    
}

class AccelWriter {
    var file: FileHandle!
    var manager: CMMotionManager!
    let filename = "accelerometer.txt"
    let header = "# timestamp, ax, ay, az\n"
    let template = "%lld, %.6f, %.6f, %.6f\n"
    
    init?(outDir: URL, manager: CMMotionManager, freq: Double) {
        if !manager.isAccelerometerAvailable { return nil }
        manager.accelerometerUpdateInterval = 1.0 / freq
        self.manager = manager
        
        let fileURL = outDir.appendingPathComponent(filename)
        if (!FileManager.default.createFile(atPath: fileURL.path, contents: header.data(using: String.Encoding.utf8),
                                            attributes: nil)) {
            os_log("Cannot create the accelerometer file at %@", type:.error, fileURL.path)
            return nil
        }
        do {
            try file = FileHandle(forWritingTo: fileURL)
        } catch {
            os_log("Cannot create the accelerometer file: %@", type:.error, error.localizedDescription)
            return nil
        }
        file.seekToEndOfFile()
    }
    
    func start(queue: OperationQueue) {
        manager.startAccelerometerUpdates(to: queue, withHandler: { (inData, error) in
            if let data = inData {  // if valid
                let strData = String(
                    format: self.template,
                    timestampToInt(data.timestamp),
                    data.acceleration.x, data.acceleration.y, data.acceleration.z)
                if let outData = strData.data(using: .utf8) {
                    self.file!.write(outData)
                } else {
                    os_log("Failed to format to the accelerometer string: %@", type: .fault, strData)
                }
            }
        })
    }
    
    func finish() {
        manager.stopAccelerometerUpdates()
        file.closeFile()
        file = nil
    }
}

class GyroWriter {
    var file: FileHandle!
    var manager: CMMotionManager!
    let filename = "gyroscope.txt"
    let header = "# timestamp, rx, ry, rz\n"
    let template = "%lld, %.6f, %.6f, %.6f\n"
    
    init?(outDir: URL, manager: CMMotionManager, freq: Double) {
        if !manager.isGyroAvailable { return nil }
        manager.gyroUpdateInterval = 1.0 / freq
        self.manager = manager
        
        let fileURL = outDir.appendingPathComponent(filename)
        if (!FileManager.default.createFile(atPath: fileURL.path, contents: header.data(using: String.Encoding.utf8),
                                            attributes: nil)) {
            os_log("Cannot create the gyroscope file at %@", type:.error, fileURL.path)
            return nil
        }
        do {
            try file = FileHandle(forWritingTo: fileURL)
        } catch {
            os_log("Cannot create the gyroscope file: %@", type:.error, error.localizedDescription)
            return nil
        }
        file.seekToEndOfFile()
    }
    
    func start(queue: OperationQueue) {
        manager.startGyroUpdates(to: queue, withHandler: { (inData, error) in
            if let data = inData {  // if valid
                let strData = String(
                    format: self.template,
                    timestampToInt(data.timestamp),
                    data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
                if let outData = strData.data(using: .utf8) {
                    self.file!.write(outData)
                } else {
                    os_log("Failed to format to the gyroscope string: %@", type: .fault, strData)
                }
            }
        })
    }
    
    func finish() {
        manager.stopGyroUpdates()
        file.closeFile()
        file = nil
    }
}

class MagnetoWriter {
    var file: FileHandle!
    var manager: CMMotionManager!
    let filename = "magnetometer.txt"
    let header = "# timestamp, mx, my, mz\n"
    let template = "%lld, %.6f, %.6f, %.6f\n"
    
    init?(outDir: URL, manager: CMMotionManager, freq: Double) {
        if !manager.isMagnetometerAvailable { return nil }
        manager.magnetometerUpdateInterval = 1.0 / freq
        self.manager = manager
        
        let fileURL = outDir.appendingPathComponent(filename)
        if (!FileManager.default.createFile(atPath: fileURL.path, contents: header.data(using: String.Encoding.utf8),
                                            attributes: nil)) {
            os_log("Cannot create the magnetometer file at %@", type:.error, fileURL.path)
            return nil
        }
        do {
            try file = FileHandle(forWritingTo: fileURL)
        } catch {
            os_log("Cannot create the magnetometer file: %@", type:.error, error.localizedDescription)
            return nil
        }
        file.seekToEndOfFile()
    }
    
    func start(queue: OperationQueue) {
        manager.startMagnetometerUpdates(to: queue, withHandler: { (inData, error) in
            if let data = inData {  // if valid
                let strData = String(
                    format: self.template,
                    timestampToInt(data.timestamp),
                    data.magneticField.x, data.magneticField.y, data.magneticField.z)
                if let outData = strData.data(using: .utf8) {
                    self.file!.write(outData)
                } else {
                    os_log("Failed to format to the magnetometer string: %@", type: .fault, strData)
                }
            }
        })
    }
    
    func finish() {
        manager.stopMagnetometerUpdates()
        file.closeFile()
        file = nil
    }
}

class FusedMotionWriter {
    var file: FileHandle!
    var manager: CMMotionManager!
    let filename = "fused_imu.txt"
    let header = "# timestamp, ax, ay, az, rx, ry, rz, mx, my, mz, gx, gy, gz, heading\n"
    let template = "%lld, " + Array(repeating: "%.6f", count: 13).joined(separator: ", ") + "\n"
    
    init?(outDir: URL, manager: CMMotionManager, freq: Double) {
        if !manager.isDeviceMotionAvailable { return nil }
        manager.deviceMotionUpdateInterval = 1.0 / freq
        self.manager = manager
        
        let fileURL = outDir.appendingPathComponent(filename)
        if (!FileManager.default.createFile(atPath: fileURL.path, contents: header.data(using: String.Encoding.utf8),
                                            attributes: nil)) {
            os_log("Cannot create the fused motion file at %@", type:.error, fileURL.path)
            return nil
        }
        do {
            try file = FileHandle(forWritingTo: fileURL)
        } catch {
            os_log("Cannot create the fused motion file: %@", type:.error, error.localizedDescription)
            return nil
        }
        file.seekToEndOfFile()
    }
    
    func start(queue: OperationQueue) {
        manager.startDeviceMotionUpdates(using: CMAttitudeReferenceFrame.xTrueNorthZVertical, to: queue, withHandler: { (inData, error) in
            if let data = inData {  // if valid
                let strData = String(
                    format: self.template,
                    timestampToInt(data.timestamp),
                    data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z,
                    data.rotationRate.x, data.rotationRate.y, data.rotationRate.z,
                    data.magneticField.field.x, data.magneticField.field.y, data.magneticField.field.z,
                    data.gravity.x, data.gravity.y, data.gravity.z,
                    data.heading)
                if let outData = strData.data(using: .utf8) {
                    self.file!.write(outData)
                } else {
                    os_log("Failed to format to the fused motion string: %@", type: .fault, strData)
                }
            }
        })
    }
    
    func finish() {
        manager.stopDeviceMotionUpdates()
        file.closeFile()
        file = nil
    }
}

class MotionWriter {
    var accelWriter: AccelWriter!
    var gyroWriter: GyroWriter!
    var magnetoWriter: MagnetoWriter!
    var fusedWriter: FusedMotionWriter!
    var manager: CMMotionManager
    var queue: OperationQueue!
    
    init?(outDir: URL, manager: CMMotionManager, freq: Double) {
        guard let accelWriter = AccelWriter(outDir: outDir, manager: manager, freq: freq) else {return nil}
        self.accelWriter = accelWriter
        guard let gyroWriter = GyroWriter(outDir: outDir, manager: manager, freq: freq) else {return nil}
        self.gyroWriter = gyroWriter
        guard let magnetoWriter = MagnetoWriter(outDir: outDir, manager: manager, freq: freq) else {return nil}
        self.magnetoWriter = magnetoWriter
        guard let fusedWriter = FusedMotionWriter(outDir: outDir, manager: manager, freq: freq) else {return nil}
        self.fusedWriter = fusedWriter
        self.manager = manager
    }
    
    func start() {
        queue = OperationQueue()
        queue.name = "IMU queue"
        queue.maxConcurrentOperationCount = 1
        
        accelWriter!.start(queue: queue)
        gyroWriter!.start(queue: queue)
        magnetoWriter!.start(queue: queue)
        fusedWriter!.start(queue: queue)
    }
    
    func finish() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
        queue.waitUntilAllOperationsAreFinished()  // use a DispatchGroup if this blocks for too long
        accelWriter.finish()
        gyroWriter.finish()
        magnetoWriter.finish()
        fusedWriter.finish()
    }
}

class LocationWriter {
    var file: FileHandle!
    let filename = "location.txt"
    let header = "# timestamp, lat, long, z, sigma_xy, sigma_z\n"
    let template = "%lld, %.6f, %.6f, %.6f, %.6f, %.6f\n"

    init?(outDir: URL) {
        let fileURL = outDir.appendingPathComponent(filename)
        if (!FileManager.default.createFile(atPath: fileURL.path, contents: header.data(using: String.Encoding.utf8), attributes: nil)) {
            os_log("Cannot create the location file at %@", type:.error, fileURL.path)
            return nil
        }
        do {
            try file = FileHandle(forWritingTo: fileURL)
        } catch {
            os_log("Cannot create the location file: %@", type:.error, error.localizedDescription)
            return nil
        }
        file.seekToEndOfFile()
    }

    func write(location: CLLocation) {
        let bootDate = Date() - ProcessInfo.processInfo.systemUptime
        let strData = String(
            format: template,
            timestampToInt(location.timestamp.timeIntervalSince(bootDate)),
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.altitude,
            location.horizontalAccuracy,
            location.verticalAccuracy)
        if let outData = strData.data(using: .utf8) {
            file!.write(outData)
        } else {
            os_log("Failed to format to the location string: %@", type: .fault, strData)
        }
    }
    
    func write_multiple(locations: [CLLocation]) {
        for location in locations {
            write(location: location)
        }
    }

    func finish() {
        file.closeFile()
        file = nil
    }
}

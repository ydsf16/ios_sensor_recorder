import AVFoundation

enum PhysicalCamera: String, CaseIterable, Codable {
    case wide, ultraWide, telephoto, front
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide, .front: return .builtInWideAngleCamera
        case .ultraWide: return .builtInUltraWideCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
    var settingsKey: String { self == .ultraWide ? "ultra" : rawValue }
    var displayName: String {
        switch self { case .wide: return "Wide"; case .ultraWide: return "Ultra Wide"; case .telephoto: return "Telephoto"; case .front: return "Front" }
    }
}

/// A virtual rear input preserves rear hardware synchronization. A front input
/// remains independent; sharing a session does not genlock front and rear.
final class MultiCameraCaptureGraph {
    struct Request {
        let cameras: Set<PhysicalCamera>
        let resolution: String
        let fps: Double
        let automaticExposure: Bool
        let maxExposureSeconds: Double
        let fixedExposureSeconds: Double
        let fixedISO: Float
        let automaticFocus: Bool
        let focusLensPositions: [PhysicalCamera: Float]
        let audioEnabled: Bool
        let depthEnabled: Bool
        let freeRunning: Bool
    }
    struct InputGroup {
        let device: AVCaptureDevice
        let cameras: Set<PhysicalCamera>
    }
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? { switch self { case .unsupported(let reason): return reason } }
    }

    let session: AVCaptureMultiCamSession
    let request: Request
    let controllers: [PhysicalCamera: AVCaptureDevice]
    let sourceDevices: [PhysicalCamera: AVCaptureDevice]
    let formats: [String: AVCaptureDevice.Format]
    let outputs: [PhysicalCamera: AVCaptureVideoDataOutput]
    let ports: [PhysicalCamera: AVCaptureInput.Port]
    let hardwareSyncCameras: Set<PhysicalCamera>
    let audioOutput: AVCaptureAudioDataOutput?
    let depthOutput: AVCaptureDepthDataOutput?
    let depthPort: AVCaptureInput.Port?
    let depthDevice: AVCaptureDevice?
    var device: AVCaptureDevice { PhysicalCamera.allCases.compactMap { controllers[$0] }.first! }
    var format: AVCaptureDevice.Format { formats[device.uniqueID]! }
    var isFullyHardwareSynchronized: Bool { hardwareSyncCameras == request.cameras }

    static func virtualDevice(for cameras: Set<PhysicalCamera>) -> AVCaptureDevice? {
        guard cameras.count > 1, !cameras.contains(.front), AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera], mediaType: .video, position: .back).devices.filter { device in
            cameras.allSatisfy { camera in device.constituentDevices.contains { $0.deviceType == camera.deviceType && $0.position == camera.position } }
        }.min { $0.constituentDevices.count < $1.constituentDevices.count }
    }

    static func inputGroups(for cameras: Set<PhysicalCamera>, depthEnabled: Bool = false,
                            freeRunning: Bool = false) -> [InputGroup]? {
        guard cameras.count > 1, AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        if freeRunning {
            let groups: [InputGroup] = PhysicalCamera.allCases.filter { cameras.contains($0) }.compactMap { camera in
                let type: AVCaptureDevice.DeviceType = camera == .wide && depthEnabled ? .builtInLiDARDepthCamera : camera.deviceType
                guard let device = AVCaptureDevice.default(type, for: .video, position: camera.position) else { return nil }
                return InputGroup(device: device, cameras: [camera])
            }
            if groups.count == cameras.count {
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInLiDARDepthCamera],
                    mediaType: .video, position: .unspecified)
                let ids = Set(groups.map { $0.device.uniqueID })
                if discovery.supportedMultiCamDeviceSets.contains(where: { Set($0.map(\.uniqueID)).isSuperset(of: ids) }) {
                    return groups
                }
            }
            // A virtual rear input may allow an additional front stream even
            // when its physical constituents cannot all be separate inputs.
            // Free mode still delivers each output independently below.
        }
        let rear = cameras.subtracting([.front])
        var groups: [InputGroup] = []
        if depthEnabled {
            guard rear == [.wide], cameras.contains(.front),
                  let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
                  let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return nil }
            groups = [InputGroup(device: lidar, cameras: [.wide]), InputGroup(device: front, cameras: [.front])]
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInLiDARDepthCamera, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            let ids = Set(groups.map { $0.device.uniqueID })
            return discovery.supportedMultiCamDeviceSets.contains { Set($0.map(\.uniqueID)).isSuperset(of: ids) } ? groups : nil
        }
        if rear.count > 1 {
            guard let virtual = virtualDevice(for: rear) else { return nil }
            groups.append(InputGroup(device: virtual, cameras: rear))
        } else if let camera = rear.first {
            guard let device = AVCaptureDevice.default(camera.deviceType, for: .video, position: camera.position) else { return nil }
            groups.append(InputGroup(device: device, cameras: rear))
        }
        if cameras.contains(.front) {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return nil }
            groups.append(InputGroup(device: device, cameras: [.front]))
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera], mediaType: .video, position: .unspecified)
        let inputIDs = Set(groups.map { $0.device.uniqueID })
        guard discovery.supportedMultiCamDeviceSets.contains(where: { Set($0.map(\.uniqueID)).isSuperset(of: inputIDs) }) else { return nil }
        return groups
    }

    static func controllerDevice(for camera: PhysicalCamera, cameras: Set<PhysicalCamera>, depthEnabled: Bool = false,
                                 freeRunning: Bool = false) -> AVCaptureDevice? {
        inputGroups(for: cameras, depthEnabled: depthEnabled, freeRunning: freeRunning)?.first { $0.cameras.contains(camera) }?.device
    }
    func controller(forSourceDevice source: AVCaptureDevice) -> AVCaptureDevice {
        guard let camera = sourceDevices.first(where: { $0.value.uniqueID == source.uniqueID })?.key else { return source }
        return controllers[camera] ?? source
    }
    static func resolution(_ format: AVCaptureDevice.Format) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return "\(size.width)x\(size.height)"
    }
    static func configureEncoderPixelFormat(_ output: AVCaptureVideoDataOutput) -> Bool {
        let supported = output.availableVideoPixelFormatTypes
        guard let format = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].first(where: { supported.contains($0) }) else { return false }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        return true
    }
    private static func canSetFixedExposure(_ device: AVCaptureDevice) -> Bool {
        device.isExposureModeSupported(.custom)
    }
    private static func matchingFormats(_ device: AVCaptureDevice, request: Request) -> [AVCaptureDevice.Format] {
        device.formats.filter { format in
            format.isMultiCamSupported && resolution(format) == request.resolution &&
            (!request.depthEnabled || device.deviceType != .builtInLiDARDepthCamera || !format.supportedDepthDataFormats.isEmpty) &&
            format.videoSupportedFrameRateRanges.contains { request.fps >= $0.minFrameRate - 0.0001 && request.fps <= $0.maxFrameRate + 0.0001 } &&
            (request.automaticExposure || (canSetFixedExposure(device) &&
             request.fixedExposureSeconds >= CMTimeGetSeconds(format.minExposureDuration) - 0.000001 &&
             request.fixedExposureSeconds <= min(CMTimeGetSeconds(format.maxExposureDuration), 1 / request.fps) + 0.000001 &&
             request.fixedISO >= format.minISO && request.fixedISO <= format.maxISO))
        }.sorted { a, b in
            if a.isVideoBinned != b.isVideoBinned { return a.isVideoBinned }
            return (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
    }
    static func make(_ request: Request, frozenFormats: [String: AVCaptureDevice.Format]? = nil) throws -> MultiCameraCaptureGraph {
        if request.depthEnabled && request.fps > 30 {
            throw Failure.unsupported("LiDAR capture supports camera frame rates up to 30 fps.")
        }
        guard let groups = inputGroups(for: request.cameras, depthEnabled: request.depthEnabled,
                                       freeRunning: request.freeRunning) else { throw Failure.unsupported("The SDK does not allow these camera inputs to run together.") }
        var lastError: Error = Failure.unsupported("No exact multi-camera format supports \(request.resolution) at \(request.fps) Hz.")
        func search(_ index: Int, _ chosen: [String: AVCaptureDevice.Format]) -> MultiCameraCaptureGraph? {
            if index == groups.count {
                do { return try MultiCameraCaptureGraph(request: request, groups: groups, formats: chosen) }
                catch { lastError = error; return nil }
            }
            let device = groups[index].device
            let options = frozenFormats.map { $0[device.uniqueID].map { [$0] } ?? [] } ?? matchingFormats(device, request: request)
            for format in options {
                var next = chosen; next[device.uniqueID] = format
                if let graph = search(index + 1, next) { return graph }
            }
            return nil
        }
        if let graph = search(0, [:]) { return graph }
        throw lastError
    }

    private init(request: Request, groups: [InputGroup], formats: [String: AVCaptureDevice.Format]) throws {
        self.request = request; self.formats = formats
        let graph = AVCaptureMultiCamSession(); session = graph
        var controllers: [PhysicalCamera: AVCaptureDevice] = [:]
        var sources: [PhysicalCamera: AVCaptureDevice] = [:]
        var outputs: [PhysicalCamera: AVCaptureVideoDataOutput] = [:]
        var ports: [PhysicalCamera: AVCaptureInput.Port] = [:]
        var hardware: Set<PhysicalCamera> = []
        var durations: [String: CMTime] = [:]
        var configuredDepthOutput: AVCaptureDepthDataOutput?
        var configuredDepthPort: AVCaptureInput.Port?
        var configuredDepthDevice: AVCaptureDevice?
        var committed = false
        graph.beginConfiguration()
        defer { if !committed { graph.commitConfiguration() } }
        for group in groups {
            let device = group.device
            guard let format = formats[device.uniqueID], Self.resolution(format) == request.resolution,
                  let range = format.videoSupportedFrameRateRanges.first(where: { request.fps >= $0.minFrameRate - 0.0001 && request.fps <= $0.maxFrameRate + 0.0001 }),
                  request.automaticExposure || (Self.canSetFixedExposure(device) &&
                    request.fixedExposureSeconds >= CMTimeGetSeconds(format.minExposureDuration) - 0.000001 &&
                    request.fixedExposureSeconds <= min(CMTimeGetSeconds(format.maxExposureDuration), 1 / request.fps) + 0.000001 &&
                    request.fixedISO >= format.minISO && request.fixedISO <= format.maxISO) else {
                throw Failure.unsupported("A frozen camera format does not match the requested dimensions and cadence.")
            }
            var duration = CMTime(seconds: 1 / request.fps, preferredTimescale: 1_000_000_000)
            if CMTimeCompare(duration, range.minFrameDuration) < 0 { duration = range.minFrameDuration }
            if CMTimeCompare(duration, range.maxFrameDuration) > 0 { duration = range.maxFrameDuration }
            durations[device.uniqueID] = duration
            try device.lockForConfiguration()
            device.activeFormat = format
            if request.depthEnabled && device.deviceType == .builtInLiDARDepthCamera {
                guard let depth = format.supportedDepthDataFormats.filter({
                    let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                    return subtype == kCVPixelFormatType_DepthFloat32 || subtype == kCVPixelFormatType_DepthFloat16
                }).max(by: { lhs, rhs in
                    let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    return Int(left.width) * Int(left.height) < Int(right.width) * Int(right.height)
                }) else {
                    device.unlockForConfiguration()
                    throw Failure.unsupported("The requested LiDAR video format has no usable depth format.")
                }
                device.activeDepthDataFormat = depth
                if let fastest = depth.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                    device.activeDepthDataMinFrameDuration = fastest.minFrameDuration
                }
            }
            if #available(iOS 18.0, *), format.isAutoVideoFrameRateSupported { device.isAutoVideoFrameRateEnabled = false }
            device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            if device.isVirtualDevice { input.unifiedAutoExposureDefaultsEnabled = true }
            guard graph.canAddInput(input) else { throw Failure.unsupported("Cannot attach a requested camera input.") }
            graph.addInputWithNoConnections(input)
            input.videoMinFrameDurationOverride = duration
            if !request.freeRunning && device.isVirtualDevice && group.cameras.count > 1 { hardware.formUnion(group.cameras) }
            for camera in PhysicalCamera.allCases where group.cameras.contains(camera) {
                let port = device.deviceType == .builtInLiDARDepthCamera
                    ? input.ports.first { $0.mediaType == .video }
                    : device.isVirtualDevice
                    ? input.ports(for: .video, sourceDeviceType: camera.deviceType, sourceDevicePosition: camera.position).first
                    : input.ports.first { $0.mediaType == .video }
                guard let port else { throw Failure.unsupported("A requested physical camera port is unavailable.") }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = false
                output.automaticallyConfiguresOutputBufferDimensions = false
                output.deliversPreviewSizedOutputBuffers = false
                guard graph.canAddOutput(output) else { throw Failure.unsupported("Cannot attach a requested camera output.") }
                graph.addOutputWithNoConnections(output)
                let connection = AVCaptureConnection(inputPorts: [port], output: output)
                guard graph.canAddConnection(connection) else { throw Failure.unsupported("Cannot connect a requested camera port.") }
                graph.addConnection(connection)
                guard Self.configureEncoderPixelFormat(output) else { throw Failure.unsupported("No SDK-supported NV12 encoder input format is available.") }
                connection.preferredVideoStabilizationMode = .off
                if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
                controllers[camera] = device
                sources[camera] = device.isVirtualDevice ? device.constituentDevices.first { $0.deviceType == camera.deviceType && $0.position == camera.position } : device
                outputs[camera] = output; ports[camera] = port
            }
            if request.depthEnabled && device.deviceType == .builtInLiDARDepthCamera {
                guard let depthPort = input.ports.first(where: { $0.mediaType == .depthData }) else {
                    throw Failure.unsupported("LiDAR input has no depth port.")
                }
                let output = AVCaptureDepthDataOutput()
                output.isFilteringEnabled = true
                output.alwaysDiscardsLateDepthData = true
                guard graph.canAddOutput(output) else { throw Failure.unsupported("Cannot attach LiDAR depth output.") }
                graph.addOutputWithNoConnections(output)
                let connection = AVCaptureConnection(inputPorts: [depthPort], output: output)
                guard graph.canAddConnection(connection) else { throw Failure.unsupported("Cannot connect LiDAR depth output.") }
                graph.addConnection(connection)
                configuredDepthOutput = output
                configuredDepthPort = depthPort
                configuredDepthDevice = device
            }
        }
        self.controllers = controllers; sourceDevices = sources; self.outputs = outputs; self.ports = ports; hardwareSyncCameras = hardware
        depthOutput = configuredDepthOutput; depthPort = configuredDepthPort; depthDevice = configuredDepthDevice
        if request.audioEnabled {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  let microphone = AVCaptureDevice.default(for: .audio) else { throw Failure.unsupported("Microphone permission is required.") }
            let input = try AVCaptureDeviceInput(device: microphone)
            guard graph.canAddInput(input) else { throw Failure.unsupported("Cannot attach the microphone.") }
            graph.addInput(input)
            let output = AVCaptureAudioDataOutput()
            guard graph.canAddOutput(output) else { throw Failure.unsupported("Cannot attach the microphone output.") }
            graph.addOutput(output); audioOutput = output
        } else { audioOutput = nil }
        graph.commitConfiguration(); committed = true
        for group in groups {
            try applyControlPolicy(group.device, cameras: group.cameras,
                                   format: formats[group.device.uniqueID]!, duration: durations[group.device.uniqueID]!)
        }
        if !request.automaticFocus {
            for camera in PhysicalCamera.allCases where request.cameras.contains(camera) {
                guard let source = sources[camera], let controller = controllers[camera],
                      !controller.isVirtualDevice,
                      source.isLockingFocusWithCustomLensPositionSupported,
                      let position = request.focusLensPositions[camera] else { continue }
                try source.lockForConfiguration()
                source.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                source.unlockForConfiguration()
            }
        }
        if let issue = configurationIssue() { close(); throw Failure.unsupported(issue) }
    }

    private func applyControlPolicy(_ device: AVCaptureDevice, cameras: Set<PhysicalCamera>,
                                    format: AVCaptureDevice.Format, duration: CMTime) throws {
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        device.automaticallyAdjustsVideoHDREnabled = false
        if format.isVideoHDRSupported { device.isVideoHDREnabled = false }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        else if device.isWhiteBalanceModeSupported(.autoWhiteBalance) { device.whiteBalanceMode = .autoWhiteBalance }
        if request.automaticExposure {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            let seconds = min(request.maxExposureSeconds, CMTimeGetSeconds(duration))
            var exposure = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            if CMTimeCompare(exposure, format.minExposureDuration) < 0 { exposure = format.minExposureDuration }
            if CMTimeCompare(exposure, format.maxExposureDuration) > 0 { exposure = format.maxExposureDuration }
            device.activeMaxExposureDuration = exposure
        } else if device.isExposureModeSupported(.custom) {
            let exposure = CMTime(seconds: request.fixedExposureSeconds, preferredTimescale: 1_000_000_000)
            device.setExposureModeCustom(duration: exposure, iso: request.fixedISO, completionHandler: nil)
        }
        if request.automaticFocus, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        } else if !request.automaticFocus, device.isFocusModeSupported(.locked) {
            if device.isLockingFocusWithCustomLensPositionSupported,
               let camera = PhysicalCamera.allCases.first(where: { cameras.contains($0) }),
               let position = request.focusLensPositions[camera] {
                device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
            } else {
                device.setFocusModeLocked(lensPosition: AVCaptureDevice.currentLensPosition, completionHandler: nil)
            }
        }
        device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
    }
    func configurationIssue(verifyFocusPosition: Bool = false) -> String? {
        for device in Dictionary(controllers.values.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first }).values {
            guard let format = formats[device.uniqueID], device.activeFormat === format else { return "A frozen camera format changed." }
            let min = CMTimeGetSeconds(device.activeVideoMinFrameDuration), max = CMTimeGetSeconds(device.activeVideoMaxFrameDuration)
            guard min > 0, max > 0, abs(1 / min - request.fps) < 0.01, abs(1 / max - request.fps) < 0.01 else { return "A camera did not retain the requested frame rate." }
            if request.automaticExposure && CMTimeGetSeconds(device.activeMaxExposureDuration) > request.maxExposureSeconds + 0.000001 { return "A camera did not retain the exposure limit." }
            if request.automaticExposure && device.isExposureModeSupported(.continuousAutoExposure) && device.exposureMode != .continuousAutoExposure { return "A camera did not retain automatic exposure." }
            if !request.automaticExposure && device.isExposureModeSupported(.custom) && device.exposureMode != .custom { return "A camera did not retain fixed exposure." }
            if request.automaticFocus && device.isFocusModeSupported(.continuousAutoFocus) && device.focusMode != .continuousAutoFocus { return "A camera did not retain automatic focus." }
            if !request.automaticFocus && device.isFocusModeSupported(.locked) && device.focusMode != .locked { return "A camera did not retain its focus lock." }
        }
        if request.depthEnabled && (depthOutput == nil || depthDevice?.activeDepthDataFormat == nil) {
            return "The LiDAR depth format was not retained."
        }
        if verifyFocusPosition && !request.automaticFocus {
            for camera in PhysicalCamera.allCases where request.cameras.contains(camera) {
                guard let source = sourceDevices[camera],
                      let controller = controllers[camera],
                      let requested = request.focusLensPositions[camera] else { continue }
                let controlled = controller.isVirtualDevice ? controller : source
                guard controlled.isLockingFocusWithCustomLensPositionSupported else { continue }
                if abs(controlled.lensPosition - requested) > 0.03 {
                    return "\(camera.displayName) did not reach the requested focus position."
                }
            }
        }
        guard session.hardwareCost.isFinite, session.systemPressureCost.isFinite, session.hardwareCost <= 1, session.systemPressureCost <= 1 else { return "The exact camera configuration exceeds the capture budget." }
        // Input-port descriptions may remain nil during startup. The controller
        // validates actual output pixel dimensions before declaring preview ready.
        return nil
    }
    func close() {
        session.stopRunning(); session.beginConfiguration()
        session.outputs.forEach { session.removeOutput($0) }; session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
    }
}

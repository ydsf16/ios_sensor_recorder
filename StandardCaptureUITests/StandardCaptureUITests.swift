import XCTest

final class StandardCaptureUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.grape.SensorRecorder")

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeRight
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["main.settings"].waitForExistence(timeout: 30))
        dismissConfigurationAlerts()
    }

    private func dismissConfigurationAlerts() {
        for _ in 0..<6 {
            let alert = app.alerts.firstMatch
            if !alert.waitForExistence(timeout: 0.5) {
                let error = app.otherElements["capture.error"]
                if error.exists && error.buttons["OK"].exists { error.buttons["OK"].tap(); continue }
                return
            }
            print("Startup notice: \(alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
            else if alert.buttons["Cancel"].exists { alert.buttons["Cancel"].tap() }
            else { XCTFail("Unexpected startup alert: \(alert)"); return }
        }
    }

    func testHardwareDiscovery() throws {
        app.terminate()
        app.launchArguments = ["--inspect-hardware"]
        app.launch()
        let status = app.staticTexts["validation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        wait(status, "value == 'done'", timeout: 60)
    }

    func testCaptureMatrixTraversal() throws {
        executionTimeAllowance = 7200
        app.terminate()
        let environment = ProcessInfo.processInfo.environment
        app.launchArguments = ["--validate-capture-matrix", "--matrix-offset", environment["CAPTURE_MATRIX_OFFSET"] ?? "0",
                               "--matrix-count", environment["CAPTURE_MATRIX_COUNT"] ?? "9999"]
        app.launch()
        let status = app.staticTexts["validation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        wait(status, "value == 'done' OR value == 'failed'", timeout: 7100)
        XCTAssertEqual(status.value as? String, "done", status.label)
        screenshot("capture_matrix_finished")
    }

    func testFinalCaptureCatalogue() throws {
        app.terminate()
        app.launchArguments = ["--validate-capture-matrix", "--matrix-count", "0"]
        app.launch()
        let status = app.staticTexts["validation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        wait(status, "value == 'done' OR value == 'failed'", timeout: 120)
        XCTAssertEqual(status.value as? String, "done", status.label)
    }

    func testHardwareMatrixTraversal() throws {
        executionTimeAllowance = 1800
        app.terminate()
        app.launchArguments = ["--validate-capture-matrix", "--matrix-hardware-only"]
        app.launch()
        let status = app.staticTexts["validation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        wait(status, "value == 'done' OR value == 'failed'", timeout: 1700)
        XCTAssertEqual(status.value as? String, "done", status.label)
    }
    func testMultiCameraMatrixTraversal() throws {
        executionTimeAllowance = 3600
        app.terminate()
        app.launchArguments = ["--validate-capture-matrix", "--matrix-multicamera-only"]
        app.launch()
        let status = app.staticTexts["validation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        wait(status, "value == 'done' OR value == 'failed'", timeout: 3500)
        XCTAssertEqual(status.value as? String, "done", status.label)
    }


    func testHardwareSyncRecordingSmoke() throws {
        configure(combination: "Wide + Ultra Wide", resolution: "640x480", rate: "30", sensors: true)
        XCTAssertFalse(app.switches["cameraOverrides"].exists)
        XCTAssertFalse(app.switches["wide.autoFocus"].exists)
        XCTAssertFalse(app.buttons["settings.menu.wide.resolution"].exists)
        screenshot("hardware_sync_configuration")
        save()
        record(seconds: 10)
    }

    func testSettingsStayLockedThroughRecordingFinalization() throws {
        configure(combination: "Wide + Ultra Wide", resolution: "1280x720", rate: "30", sensors: true)
        save()
        let toggle = app.buttons["record.toggle"]
        toggle.tap()
        XCTAssertFalse(app.buttons["main.settings"].isEnabled)
        wait(toggle, "value == 'recording'", timeout: 20)
        Thread.sleep(forTimeInterval: 3)
        toggle.tap()
        if toggle.value as? String == "finishing" {
            XCTAssertFalse(app.buttons["main.settings"].isEnabled)
        }
        wait(toggle, "value == 'idle' AND enabled == true", timeout: 45)
        XCTAssertTrue(app.buttons["main.settings"].isEnabled)
    }

    func testSDKSupported60FPSRecording() throws {
        configure(combination: "Wide", resolution: "1920x1080", rate: "60", sensors: true)
        let rate = app.buttons["settings.menu.shared.frameRate"]
        reveal(rate); rate.tap()
        XCTAssertTrue(menuOption("60").waitForExistence(timeout: 120))
        XCTAssertFalse(menuOption("120").exists)
        XCTAssertFalse(menuOption("240").exists)
        menuOption("60").tap()
        save(); record(seconds: 10)
    }

    func testResolutionChangeSelectsCompatibleSDKFrameRate() throws {
        for (combination, larger) in [("Wide", "4032x3024"), ("Wide + Ultra Wide", "3840x2160")] {
            configure(combination: combination, resolution: "1920x1080", rate: "60", sensors: true)
            select("shared.resolution", larger)
            XCTAssertEqual(app.buttons["settings.menu.shared.frameRate"].value as? String, "30")
            let rate = app.buttons["settings.menu.shared.frameRate"]
            reveal(rate); rate.tap()
            XCTAssertTrue(menuOption("30").waitForExistence(timeout: 120))
            XCTAssertFalse(menuOption("60").exists)
            menuOption("30").tap()
            screenshot("resolution_updates_sdk_rates")
            save(); record(seconds: 5)
            app.buttons["main.settings"].tap()
            select("shared.resolution", "1920x1080")
            XCTAssertEqual(app.buttons["settings.menu.shared.frameRate"].value as? String, "30", "A compatible current rate must be preserved")
            select("shared.frameRate", "60")
            save(); record(seconds: 3)
        }
    }

    func testSDK4K60Recording() throws {
        configure(combination: "Wide", resolution: "3840x2160", rate: "60", sensors: true)
        save(); record(seconds: 30)
    }

    func testSDKRearPair4K30Recording() throws {
        configure(combination: "Wide + Ultra Wide", resolution: "3840x2160", rate: "30", sensors: true)
        save(); record(seconds: 10)
    }

    func testRearPairFractionalSensorCadencesRemainStable() throws {
        for _ in 0..<2 {
            for rate in ["48", "50"] {
                configure(combination: "Wide + Ultra Wide", resolution: "1920x1440", rate: rate, sensors: true)
                setSwitch("shared.autoFocus", true)
                setSwitch("shared.autoExposure", true)
                select("shared.maxExposure", "10")
                save()
                record(seconds: 30)
            }
        }
    }

    func testSDKFrontPair4K30Recording() throws {
        configure(combination: "Wide + Front", resolution: "3840x2160", rate: "30", sensors: true)
        save(); record(seconds: 10)
    }

    func testHardwareLinkedControlsAndAudio() throws {
        configure(combination: "Wide + Ultra Wide", resolution: "1280x720", rate: "30", sensors: true)
        setSwitch("shared.autoFocus", true)
        setSwitch("shared.autoExposure", true)
        select("shared.maxExposure", "5")
        let audio = app.switches["audio"]
        reveal(audio)
        audio.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许", "Allow", "好", "OK"] where springboard.alerts.firstMatch.buttons[title].waitForExistence(timeout: 1) {
            springboard.alerts.firstMatch.buttons[title].tap()
        }
        wait(audio, "value == '1'", timeout: 10)
        save()
        record(seconds: 10)
        app.buttons["main.settings"].tap()
        setSwitch("shared.autoFocus", false)
        select("shared.maxExposure", "20")
        save()
        record(seconds: 10)
    }

    func testBackgroundInterruptionStopsWithoutDowngrade() throws {
        configure(combination: "Wide + Ultra Wide", resolution: "640x480", rate: "30", sensors: false)
        save()
        let toggle = app.buttons["record.toggle"]
        toggle.tap()
        wait(toggle, "value == 'recording'", timeout: 20)
        Thread.sleep(forTimeInterval: 3)
        // Xcode's synthetic Home event can be ignored on this device. Activate
        // another real app and prove background state before checking recovery.
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        Thread.sleep(forTimeInterval: 3)
        screenshot("capture_is_backgrounded")
        XCTAssertNotEqual(app.state, .runningForeground, "The capture app must actually enter the background")
        app.activate()
        wait(toggle, "value == 'idle' AND enabled == true", timeout: 30)
        let alert = app.alerts.firstMatch
        let error = app.otherElements["capture.error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 1) || error.waitForExistence(timeout: 10))
        let panel = alert.exists ? alert : error
        XCTAssertTrue(panel.staticTexts.allElementsBoundByIndex.map(\.label).joined().contains("interrupted"))
        screenshot("capture_interruption_reported")
        dismissConfigurationAlerts()
    }

    func testFrontCameraCombinationsRecordingSmoke() throws {
        for combination in ["Wide + Front", "Ultra Wide + Front", "Wide + Ultra Wide + Front"] {
            configure(combination: combination, resolution: "640x480", rate: "30", sensors: true)
            let summary = app.staticTexts["settings.syncSummary"]
            reveal(summary)
            XCTAssertTrue(summary.label.lowercased().contains("timestamp"))
            if combination == "Wide + Ultra Wide + Front" { XCTAssertTrue(summary.label.lowercased().contains("hardware sync")) }
            screenshot("mixed_camera_configuration")
            save()
            record(seconds: 10)
        }
    }

    func testMixedSynchronizationWarningCanBeCancelled() throws {
        configure(combination: "Wide", resolution: "640x480", rate: "30", sensors: false)
        let combination = app.buttons["settings.menu.cameraCombination"]
        reveal(combination)
        combination.tap()
        menuOption("Wide + Ultra Wide + Front").tap()
        let warning = app.alerts["Camera Synchronization"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        let message = warning.staticTexts.allElementsBoundByIndex.map(\.label).joined()
        XCTAssertTrue(message.contains("Only the rear camera views are hardware synchronized"))
        XCTAssertTrue(message.contains("Front records independently"))
        warning.buttons["Cancel"].tap()
        XCTAssertEqual(combination.value as? String, "Wide")
        save()
    }

    func testSavedARKitToStandardTransitions() throws {
        configure(combination: "Wide", resolution: "640x480", rate: "30", sensors: false)
        save()
        for _ in 0..<2 {
            app.buttons["main.settings"].tap()
            select("captureMode", "ARKit")
            save()
            // Canceling a Standard draft must resume the same ARKit preview.
            app.buttons["main.settings"].tap()
            select("captureMode", "Standard")
            closeSettings()
            XCTAssertFalse(app.otherElements["capture.error"].exists)
            // Actually save the transition, exercising session teardown rather
            // than only rebuilding controls inside an uncommitted draft.
            configure(combination: "Wide", resolution: "640x480", rate: "30", sensors: false)
            save()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                XCTAssertFalse(app.otherElements["capture.error"].exists, "A retired ARKit session reported an error in Standard")
                Thread.sleep(forTimeInterval: 0.3)
            }
            record(seconds: 3)
        }
    }

    func testSustainedTripleCameraRecording() throws {
        configure(combination: "Wide + Ultra Wide + Front", resolution: "1920x1080", rate: "30", sensors: true)
        save()
        record(seconds: 60)
    }

    func testIndependentSensorChannelsWithAudio() throws {
        configure(combination: "Wide", resolution: "1920x1080", rate: "30", sensors: true)
        for key in ["mag", "baro", "geo", "audio"] { setSwitch(key, true); allowSystemPermissions() }
        save()
        record(seconds: 25)
    }

    func testARKitIndependentWriterAndPreview() throws {
        app.buttons["main.settings"].tap()
        select("captureMode", "ARKit")
        setSwitch("arkit.autoFocus", true)
        setSwitch("arkit.autoExposure", true)
        select("arkit.resolution", "1920x1440")
        select("arkit.frameRate", "30")
        save()
        record(seconds: 15)
    }

    func testSustainedARKitIndependentWriterAndPreview() throws {
        app.buttons["main.settings"].tap()
        select("captureMode", "ARKit")
        setSwitch("arkit.autoFocus", true)
        setSwitch("arkit.autoExposure", true)
        select("arkit.resolution", "1920x1440")
        select("arkit.frameRate", "30")
        for key in ["imu", "motion", "mag", "baro", "geo", "audio"] { setSwitch(key, false) }
        save()
        record(seconds: 60)
    }

    func testLongPreview01Triple1080p60() throws {
        configure(combination: "Wide + Ultra Wide + Front", resolution: "1920x1080", rate: "60", sensors: true)
        setSwitch("audio", true); allowSystemPermissions()
        save(); record(seconds: 90)
    }

    func testLongPreview02Wide4K60() throws {
        configure(combination: "Wide", resolution: "3840x2160", rate: "60", sensors: true)
        save(); record(seconds: 90)
    }

    func testLongPreview03RearPair4K30() throws {
        configure(combination: "Wide + Ultra Wide", resolution: "3840x2160", rate: "30", sensors: true)
        save(); record(seconds: 90)
    }

    func testTripleCameraPreviewDuring60FPSRecording() throws {
        configure(combination: "Wide + Ultra Wide + Front", resolution: "1920x1080", rate: "60", sensors: false)
        save()
        record(seconds: 15)
    }

    func testSingleCameraFocusAndPersistence() throws {
        configure(combination: "Wide", resolution: "1280x720", rate: "30", sensors: true)
        setSwitch("wide.autoFocus", false)
        let focus = app.sliders["wide.fixedFocus"]
        reveal(focus)
        XCTAssertTrue(focus.isEnabled)
        focus.adjust(toNormalizedSliderPosition: 0.4)
        save()
        record(seconds: 8)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["main.settings"].waitForExistence(timeout: 30))
        dismissConfigurationAlerts()
        app.buttons["main.settings"].tap()
        reveal(app.segmentedControls["settings.focusMode.wide"])
        XCTAssertTrue(app.segmentedControls["settings.focusMode.wide"].buttons["Manual"].isSelected)
        reveal(app.sliders["wide.fixedFocus"])
        XCTAssertTrue(app.sliders["wide.fixedFocus"].isEnabled)
        let value = try XCTUnwrap(app.sliders["wide.fixedFocus"].value as? String)
        let number = try XCTUnwrap(Double(value.replacingOccurrences(of: "%", with: "")))
        XCTAssertEqual(number, 40, accuracy: 3)
        screenshot("single_manual_focus_persisted")
        closeSettings()
    }

    func testAllDeviceCameraCombinationsAreOffered() throws {
        app.buttons["main.settings"].tap()
        select("captureMode", "Standard")
        let menu = app.buttons["settings.menu.cameraCombination"]
        reveal(menu)
        menu.tap()
        let wide = menuOption("Wide")
        XCTAssertTrue(wide.waitForExistence(timeout: 120))
        XCTAssertTrue(menuOption("Wide + Front").exists)
        XCTAssertTrue(menuOption("Ultra Wide + Front").exists)
        XCTAssertTrue(menuOption("Wide + Ultra Wide + Front").exists)
        XCTAssertTrue(menuOption("Wide + Ultra Wide").exists)
        let names = ["Wide", "Ultra Wide", "Front", "Wide + Ultra Wide", "Wide + Front", "Ultra Wide + Front", "Wide + Ultra Wide + Front"]
        let displayed = app.buttons.allElementsBoundByIndex.filter { names.contains($0.label) && !$0.identifier.hasPrefix("settings.") }.map(\.label)
        XCTAssertEqual(displayed, names, "Camera choices must be ordered by camera count")
        screenshot("hardware_combinations")
        wide.tap()
        XCTAssertFalse(app.switches["cameraOverrides"].exists)
        XCTAssertFalse(app.buttons["settings.recheck"].exists)
        for name in ["camera", "capture", "focus", "lidar", "sensors", "account"] {
            XCTAssertTrue(app.otherElements["settings.card.\(name)"].exists, "Missing expanded card: \(name)")
        }
        save()
    }

    func testPortraitSettingsAndLandscapeReturn() throws {
        app.buttons["main.settings"].tap()
        orientation(portrait: true)
        XCTAssertTrue(app.buttons["settings.menu.cameraCombination"].exists)
        XCTAssertTrue(app.buttons["settings.menu.shared.resolution"].exists)
        XCTAssertFalse(app.switches["cameraOverrides"].exists)
        screenshot("portrait_settings_top")
        reveal(app.switches["lidarDepth"])
        screenshot("portrait_settings_depth")
        closeSettings()
        orientation(portrait: false)
        dismissConfigurationAlerts()
        wait(app.buttons["main.settings"], "hittable == true", timeout: 15)
        screenshot("landscape_return")
        app.buttons["main.settings"].tap()
        orientation(portrait: true)
        closeSettings()
    }

    func testPurchaseControlsRemainAccessible() throws {
        app.buttons["main.settings"].tap()
        orientation(portrait: true)
        let account = app.otherElements["settings.card.account"]
        let mode = app.otherElements["settings.card.mode"]
        let camera = app.otherElements["settings.card.camera"]
        XCTAssertTrue(account.exists && mode.exists && camera.exists)
        XCTAssertLessThan(account.frame.minY, mode.frame.minY)
        XCTAssertLessThan(mode.frame.minY, camera.frame.minY)
        let restore = app.buttons["purchase.restore"]
        XCTAssertTrue(restore.isHittable, "Account actions must be visible without scrolling")
        reveal(restore)
        XCTAssertTrue(restore.isHittable)
        XCTAssertTrue(app.buttons["purchase.upgrade"].exists)
        XCTAssertTrue(app.staticTexts["purchase.status"].exists)
        screenshot("purchase_controls")
        let developer = app.buttons["settings.developer.moreInfo"]
        reveal(developer)
        XCTAssertTrue(developer.isHittable)
        XCTAssertEqual(developer.label, "TinyGrapeLab")
        screenshot("developer_information")
        closeSettings()
    }

    func testSettingsFollowPreferredLanguage() throws {
        for (language, locale, title, saveTitle) in [("en", "en_US", "Settings", "Save Settings"),
                                                    ("zh-Hans", "zh_CN", "设置", "保存设置"),
                                                    ("zh-Hant", "zh_TW", "设置", "保存设置"),
                                                    ("fr", "fr_FR", "Settings", "Save Settings")] {
            app.terminate()
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            XCTAssertTrue(app.buttons["main.settings"].waitForExistence(timeout: 30))
            dismissConfigurationAlerts()
            screenshot("capture_\(language)")
            app.buttons["main.settings"].tap()
            XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout: 20))
            XCTAssertEqual(app.buttons["settings.save"].label, saveTitle)
            XCTAssertTrue(app.staticTexts[title].exists)
            screenshot("settings_\(language)")
            let brand = app.buttons["settings.developer.moreInfo"]
            reveal(brand)
            XCTAssertTrue(brand.isHittable)
            screenshot("developer_\(language)")
            closeSettings()
        }
        app.terminate()
        app.launchArguments = []
        app.launch()
    }

    func testExpandedCardsPreserveSensorDraftAcrossCameraAndModeChanges() throws {
        configure(combination: "Wide", resolution: "1280x720", rate: "30", sensors: true)
        setSwitch("mag", true)
        select("cameraCombination", "Wide + Ultra Wide")
        XCTAssertEqual(app.switches["mag"].value as? String, "1")
        select("captureMode", "ARKit")
        XCTAssertTrue(app.buttons["settings.menu.arkit.resolution"].exists)
        select("captureMode", "Standard")
        XCTAssertEqual(app.switches["mag"].value as? String, "1")
        XCTAssertTrue(app.otherElements["settings.card.lidar"].exists)
        XCTAssertTrue(app.otherElements["settings.card.account"].exists)
        XCTAssertFalse(app.buttons["settings.recheck"].exists)
        closeSettings()
    }

    func testFreeRecordingLimit() throws {
        app.buttons["main.settings"].tap()
        let status = app.staticTexts["purchase.status"]
        reveal(status)
        if status.label.hasPrefix("Premium unlocked") { throw XCTSkip("Real account is Premium; do not alter its entitlement.") }
        XCTAssertTrue(status.label.contains("2 minutes"))
        closeSettings()
        dismissConfigurationAlerts()
        configure(combination: "Wide + Ultra Wide", resolution: "3840x2160", rate: "30", sensors: true)
        save()
        let toggle = app.buttons["record.toggle"]
        wait(toggle, "enabled == true", timeout: 45)
        toggle.tap()
        wait(toggle, "value == 'recording'", timeout: 20)
        wait(toggle, "value == 'idle' AND enabled == true", timeout: 135)
        XCTAssertTrue(app.alerts["Free Recording Limit Reached"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.firstMatch.buttons["Upgrade"].exists)
        XCTAssertTrue(app.alerts.firstMatch.buttons["Restore Purchase"].exists)
        screenshot("free_limit_stopped")
        app.alerts.firstMatch.buttons["Later"].tap()
    }

    private func closeSettings() {
        app.buttons["settings.close"].tap()
        wait(app.buttons["main.settings"], "enabled == true AND hittable == true", timeout: 20)
        orientation(portrait: false)
    }

    private func configure(combination: String, resolution: String, rate: String, sensors: Bool) {
        if !app.buttons["settings.close"].exists { app.buttons["main.settings"].tap() }
        XCTAssertTrue(app.buttons["settings.menu.captureMode"].waitForExistence(timeout: 15))
        select("captureMode", "Standard")
        select("cameraCombination", combination)
        for key in ["lidarDepth", "mag", "baro", "geo", "audio"] { setSwitch(key, false) }
        setSwitch("imu", sensors)
        setSwitch("motion", sensors)
        // Move through a common SDK-supported cadence before changing dimensions.
        if app.buttons["settings.menu.shared.resolution"].value as? String != resolution {
            select("shared.frameRate", "30")
            select("shared.resolution", resolution)
        }
        select("shared.frameRate", rate)
        select("shared.resolution", resolution)
        // Changing dimensions must not silently change cadence.
        XCTAssertEqual(app.buttons["settings.menu.shared.frameRate"].value as? String, rate)
    }

    private func save() {
        wait(app.buttons["settings.save"], "enabled == true", timeout: 90)
        app.buttons["settings.save"].tap()
        let completion = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["record.toggle"].isEnabled || self.app.otherElements["capture.error"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completion], timeout: 60), .completed)
        if app.otherElements["capture.error"].exists {
            screenshot("settings_save_error")
            XCTFail(app.otherElements["capture.error"].debugDescription)
            return
        }
        wait(app.buttons["main.settings"], "enabled == true AND hittable == true", timeout: 20)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
    }

    @discardableResult
    private func allowSystemPermissions() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists else { return false }
        let using = alert.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "使用", "允许")).firstMatch
        if using.exists { using.tap(); return true }
        for title in ["Allow While Using App", "Allow Once", "Allow", "OK", "允许一次", "允许", "好"] {
            if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
        }
        return false
    }

    private func record(seconds: TimeInterval) {
        let toggle = app.buttons["record.toggle"]
        toggle.tap()
        let permissionDeadline = Date().addingTimeInterval(30)
        while toggle.value as? String != "recording", Date() < permissionDeadline {
            allowSystemPermissions()
            if app.otherElements["capture.error"].exists { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        wait(toggle, "value == 'recording'", timeout: 2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 0.5)
            for title in ["允许", "Allow"] where springboard.alerts.firstMatch.buttons[title].exists {
                springboard.alerts.firstMatch.buttons[title].tap()
            }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(toggle.value as? String, "recording", "Recording stopped before the requested duration")
            XCTAssertFalse(app.otherElements["capture.error"].exists, "Recording reported a failure")
        }
        screenshot("recording")
        toggle.tap()
        wait(toggle, "value == 'idle' AND enabled == true", timeout: 45)
    }

    private func menuOption(_ value: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT identifier BEGINSWITH %@", value, "settings.")).firstMatch
    }

    private func select(_ key: String, _ value: String) {
        let button = app.buttons["settings.menu.\(key)"]
        reveal(button)
        if button.value as? String == value { return }
        button.tap()
        let option = menuOption(value)
        if key.hasSuffix(".frameRate") || key.hasSuffix(".resolution") {
            let pattern = key.hasSuffix(".frameRate") ? "[0-9]+([.][0-9]+)?" : "[0-9]+x[0-9]+"
            let query = app.buttons.matching(NSPredicate(format: "label MATCHES %@ AND NOT identifier BEGINSWITH %@", pattern, "settings."))
            XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 120))
            for _ in 0..<30 {
                if option.exists && option.isHittable { break }
                let rows = query.allElementsBoundByIndex.filter(\.isHittable)
                guard let first = rows.first else { break }
                let rect = rows.dropFirst().reduce(first.frame) { $0.union($1.frame) }
                let numeric: (String) -> Double = { $0.split(separator: "x").compactMap { Double($0) }.reduce(1, *) }
                let numbers = rows.map { numeric($0.label) }
                let upward = key.hasSuffix(".frameRate") ? numeric(value) > (numbers.max() ?? 0) : numeric(value) < (numbers.min() ?? 0)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let top = origin.withOffset(CGVector(dx: rect.midX, dy: rect.minY + 12))
                let bottom = origin.withOffset(CGVector(dx: rect.midX, dy: rect.maxY - 12))
                (upward ? bottom : top).press(forDuration: 0.05, thenDragTo: upward ? top : bottom)
            }
        }
        XCTAssertTrue(option.waitForExistence(timeout: 120), "\(key) does not offer \(value)")
        option.tap()
        if key == "cameraCombination", value.contains("Front"), value != "Front" {
            let warning = app.alerts["Camera Synchronization"]
            XCTAssertTrue(warning.waitForExistence(timeout: 5))
            XCTAssertTrue(warning.staticTexts.allElementsBoundByIndex.map(\.label).joined().contains("timestamp"))
            screenshot("mixed_sync_warning")
            warning.buttons["Use This Combination"].tap()
        }
        XCTAssertEqual(button.value as? String, value)
    }

    private func setSwitch(_ key: String, _ on: Bool) {
        if key.hasSuffix(".autoFocus") {
            let prefix = String(key.dropLast(".autoFocus".count))
            let control = app.segmentedControls["settings.focusMode.\(prefix)"]
            if control.exists {
                reveal(control)
                let option = control.buttons.element(boundBy: on ? 0 : 1)
                if !option.isSelected { option.tap() }
                XCTAssertTrue(option.isSelected)
                return
            }
        }
        let toggle = app.switches[key]
        guard toggle.exists else { XCTAssertFalse(on, "Missing control: \(key)"); return }
        guard toggle.isEnabled else { XCTAssertFalse(on, "Disabled control: \(key)"); return }
        if (toggle.value as? String == "1") == on { return }
        reveal(toggle)
        // The device's AssistiveTouch button can sit over the trailing sensor
        // switches and send Home instead of toggling them. Keep taps in the
        // upper part of the scroll view without changing accessibility settings.
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<4 where toggle.frame.midY > app.frame.height * 0.55 {
            let before = toggle.frame.midY
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            if abs(toggle.frame.midY - before) < 2 { break }
        }
        // At the end of the scroll content a switch cannot move any farther up.
        // Its leading edge remains outside the trailing AssistiveTouch overlay.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(app.state, .runningForeground, "A system overlay intercepted the settings tap")
        wait(toggle, "value == '\(on ? "1" : "0")'", timeout: 10)
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.scrollViews.firstMatch
        func fullyVisible() -> Bool {
            guard element.exists, element.isHittable else { return false }
            // XCTest may call a clipped switch hittable even when its tap point
            // is covered by the fixed action bar. Scroll the entire control in.
            return scroll.frame.contains(element.frame)
        }
        if fullyVisible() { return }
        if !element.exists {
            let top = app.buttons["settings.menu.captureMode"]
            for _ in 0..<12 {
                if top.exists && top.isHittable { break }
                scroll.swipeDown()
            }
        }
        for _ in 0..<28 {
            if fullyVisible() { return }
            let towardTop = element.exists && element.frame.midY < scroll.frame.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.3 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        screenshot("unreachable")
        XCTFail("Control could not be reached: \(element)")
    }

    private func orientation(portrait: Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            portrait ? self.app.frame.width < self.app.frame.height : self.app.frame.width > self.app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }

    private func wait(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: timeout)
        if result != .completed {
            print("Unmet predicate: \(predicate); element: \(element.debugDescription); application: \(app.state.rawValue)")
            screenshot("predicate_failure_before_teardown")
        }
        XCTAssertEqual(result, .completed)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class SettingsScreenshotUITests: XCTestCase {
    func testCaptureExistingSettingsForLongImage() throws {
        let app = XCUIApplication(bundleIdentifier: "com.grape.SensorRecorder")
        if app.state != .runningForeground { app.activate() }
        if !app.buttons["settings.close"].exists { app.buttons["main.settings"].tap() }
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 20))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<3 { scroll.swipeDown() }
        for index in 0..<6 {
            Thread.sleep(forTimeInterval: 1)
            print("SETTINGS_CAPTURE_\(index): \(app.debugDescription)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "settings_long_\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if index < 5 {
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)))
            }
        }
        for _ in 0..<3 { scroll.swipeDown() }
    }
}

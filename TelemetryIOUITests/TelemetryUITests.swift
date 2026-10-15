import XCTest

/// Drives the shipped SwiftUI controls. No app model or synthetic hardware injection is used.
final class TelemetryUITests: XCTestCase {
    private var currentApplication: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFieldDragCreatesTouchTelemetryAndAllVisualizationModesWork() throws {
        let app = launch()
        let field = app.descendants(matching: .any)["Interactive signal field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65))
            .press(forDuration: 0.15, thenDragTo: field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)))
        screenshot(app, "01-field-orbit-after-touch")
        let modes = app.segmentedControls["field-mode"]
        XCTAssertTrue(modes.exists)
        modes.buttons["Scope"].tap()
        XCTAssertTrue(modes.buttons["Scope"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Movement energy trace").firstMatch.exists)
        screenshot(app, "02-field-scope")
        modes.buttons["Waterfall"].tap()
        XCTAssertTrue(modes.buttons["Waterfall"].isSelected)
        XCTAssertTrue(app.staticTexts["CHANNEL HISTORY"].exists)
        screenshot(app, "03-field-waterfall")
        modes.buttons["Orbit"].tap()
        XCTAssertTrue(field.exists)
        app.tabBars.buttons["Channels"].tap()
        search(app, for: "Touch X")
        let row = app.buttons["channel-touch.x"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("LIVE"), row.label)
        let value = try firstNumber(in: row)
        XCTAssertGreaterThan(value, 60, "A real drag must reach the touch telemetry readout.")
        XCTAssertLessThan(value, 100)
        screenshot(app, "04-touch-channel-after-drag")
        app.tabBars.buttons["Field"].tap()
        let scroll = app.scrollViews["field-scroll"]
        let gain = app.sliders["dial-slider-Gain"]
        tapToReveal(gain, scrolling: scroll)
        adjustSlider(gain, to: 0.4, range: 0.25...4, expected: "1.75 ×")
        XCTAssertEqual(gain.value as? String, "1.75 ×")
        let window = app.sliders["dial-slider-Window"]
        tapToReveal(window, scrolling: scroll)
        adjustSlider(window, to: 0.5, range: 2...30, expected: "16.0 s")
        XCTAssertEqual(window.value as? String, "16.0 s")
        let gainDial = app.descendants(matching: .any)["dial-Gain"]
        gainDial.doubleTap()
        XCTAssertEqual(gain.value as? String, "1.00 ×")
        screenshot(app, "04a-field-tuning-controls")
    }

    @MainActor
    func testChannelSearchInspectorHistoryAndShowInField() {
        let app = launch(arguments: ["-demo"])
        app.tabBars.buttons["Channels"].tap()
        search(app, for: "Air pressure")
        let row = app.buttons["channel-pressure"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["channel-accel.x"].exists)
        row.tap()
        XCTAssertTrue(app.navigationBars["Air pressure"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Source status: DEMO"].exists)
        screenshot(app, "05-channel-inspector-demo-provenance")
        let trace = app.descendants(matching: .any)["Air pressure trace"]
        XCTAssertTrue(trace.exists)
        trace.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.1, thenDragTo: trace.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        XCTAssertTrue(app.buttons["Return live"].waitForExistence(timeout: 3))
        app.buttons["Return live"].tap()
        tap(app.buttons["Show in Field"], scrolling: app.scrollViews["inspector-scroll"])
        XCTAssertTrue(app.tabBars.buttons["Field"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["Interactive signal field"].value as? String != nil)
        XCTAssertTrue((app.descendants(matching: .any)["Interactive signal field"].value as? String ?? "").contains("Air pressure"))
        screenshot(app, "06-channel-shown-in-field")
    }

    @MainActor
    func testTouchPresetBypassInversionAddAndRemoveRealPatchRoutes() {
        let app = launch(arguments: ["-patch"])
        let touchPreset = app.buttons["patch-preset-Touch → tone"]
        if !touchPreset.isHittable {
            for _ in 0..<3 where !touchPreset.isHittable { app.scrollViews["patch-presets"].swipeLeft() }
        }
        XCTAssertTrue(touchPreset.waitForExistence(timeout: 5))
        touchPreset.tap()
        let scroll = app.scrollViews["patch-scroll"]
        let pitchRoute = app.descendants(matching: .any)["patch-route-touch.x-Tone pitch"]
        let bypass = app.switches["patch-enable-touch.x-Tone pitch"]
        tap(bypass, scrolling: scroll, anchor: pitchRoute)
        assertSwitch(bypass, hasValue: "0", in: app)
        XCTAssertTrue(app.staticTexts["Route bypassed. The input can still be measured; this connection adds no modulation."].exists)
        screenshot(app, "07-patch-route-bypassed")
        tapControl(bypass)
        assertSwitch(bypass, hasValue: "1", in: app)
        let depth = pitchRoute.sliders["dial-slider-Depth"]
        tapToReveal(depth, scrolling: scroll, anchor: pitchRoute)
        adjustSlider(depth, to: 0.25, range: 0...1, expected: "25 %")
        XCTAssertEqual(depth.value as? String, "25 %")
        let smoothing = pitchRoute.sliders["dial-slider-Smoothing"]
        tapToReveal(smoothing, scrolling: scroll, anchor: pitchRoute)
        adjustSlider(smoothing, to: 0.75, range: 0...1, expected: "75 %")
        XCTAssertEqual(smoothing.value as? String, "75 %")
        screenshot(app, "07a-patch-depth-smoothing")
        let inversion = app.buttons["patch-invert-touch.x-Tone pitch"]
        tap(inversion, scrolling: scroll, anchor: pitchRoute)
        XCTAssertEqual(inversion.value as? String, "On")
        screenshot(app, "08-patch-route-inverted")
        tap(app.buttons["patch-remove-touch.x-Tone pitch"], scrolling: scroll, anchor: pitchRoute)
        XCTAssertFalse(bypass.exists)
        tap(app.buttons["patch-source-picker"], scrolling: scroll, toward: .top)
        XCTAssertTrue(app.navigationBars["Choose an input"].waitForExistence(timeout: 5))
        search(app, for: "Touch X")
        let touchInput = app.buttons["patch-input-touch.x"]
        XCTAssertTrue(touchInput.waitForExistence(timeout: 5))
        touchInput.tap()
        XCTAssertTrue(app.buttons["patch-source-picker"].label.contains("Touch X"))
        // The composer's initial destination is Field energy, distinct from the tone preset.
        tap(app.buttons["patch-connect"], scrolling: scroll, toward: .top)
        let addedRoute = app.switches["patch-enable-touch.x-Field energy"]
        tapToReveal(addedRoute, scrolling: scroll, anchor: app.descendants(matching: .any)["patch-route-touch.x-Field energy"])
        XCTAssertTrue(addedRoute.exists)
        assertSwitch(addedRoute, hasValue: "1", in: app)
        screenshot(app, "09-patch-new-touch-field-route")
        tap(app.buttons["patch-remove-touch.x-Field energy"], scrolling: scroll)
        XCTAssertFalse(addedRoute.exists)
    }

    @MainActor
    func testSourceMenuDemoSensorTogglePauseResumeAndCSVExport() {
        let app = launch()
        app.buttons["source-menu"].tap()
        menuItem(app, "Demo signals").tap()
        XCTAssertTrue(app.staticTexts["A PLAYABLE DEMO OF THE INSTRUMENT"].waitForExistence(timeout: 5))
        screenshot(app, "10-source-demo-enabled")
        app.buttons["source-menu"].tap()
        menuItem(app, "Demo signals").tap()
        XCTAssertTrue(app.staticTexts["LIVE INPUTS · LOCAL OUTPUTS"].waitForExistence(timeout: 5))
        app.buttons["source-menu"].tap()
        menuItem(app, "Sensor access").tap()
        XCTAssertTrue(app.navigationBars["Sensor access"].waitForExistence(timeout: 5))
        // Simulator Motion is unavailable, so this explicit toggle does not open a permission dialog.
        let motion = app.switches["Motion & magnetic field"]
        XCTAssertTrue(motion.exists)
        tapControl(motion)
        assertSwitch(motion, hasValue: "1", in: app)
        tapControl(motion)
        assertSwitch(motion, hasValue: "0", in: app)
        screenshot(app, "11-source-access-controls")
        app.buttons["Done"].tap()
        let transport = app.buttons["capture-transport"]
        transport.tap()
        XCTAssertEqual(transport.label, "Resume capture")
        screenshot(app, "12-capture-paused")
        transport.tap()
        XCTAssertEqual(transport.label, "Pause capture")
        app.tabBars.buttons["Session"].tap()
        let export = app.buttons["export-csv"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        XCTAssertTrue(app.buttons["Share capture"].waitForExistence(timeout: 5))
        screenshot(app, "13-session-csv-prepared")
        app.buttons["share-capture"].tap()
        let shareAction = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@", "Copy", "Save to Files")).firstMatch
        XCTAssertTrue(shareAction.waitForExistence(timeout: 10), "The system share sheet must receive the generated CSV.")
        XCTAssertTrue(app.otherElements["LP.CaptionBar.BottomCaption"].label.hasPrefix("TelemetryIO-") && app.otherElements["LP.CaptionBar.BottomCaption"].label.hasSuffix(".csv"), "The native share sheet must identify the exported CSV.")
        screenshot(app, "14-session-system-share-sheet")
        dismissShareSheet(app)
        app.buttons["source-menu"].tap()
        menuItem(app, "About this instrument").tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["An instrument for the signals your phone can share."].exists)
        tapToReveal(app.links["Apple sensor and privacy documentation"], scrolling: app.scrollViews["about-scroll"])
        XCTAssertTrue(app.links["Apple sensor and privacy documentation"].isHittable)
        screenshot(app, "15-about-provenance-and-documentation")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Session"].isSelected)
    }

    @MainActor
    func testEveryChannelGroupSearchEmptyStateInspectorEnableStopAndPatchShortcut() {
        let app = launch(arguments: ["-channels"])
        let scroll = app.scrollViews["channels-scroll"]
        let groups = app.scrollViews["channel-groups"]
        tapToReveal(groups, scrolling: scroll, toward: .top)
        let representatives = [("Motion", "accel.x"), ("Environment", "pressure"), ("Location", "location.latitude"), ("Audio", "mic.rms"), ("Radio", "network.wifi"), ("Device", "device.battery"), ("Interaction", "touch.x"), ("Output", "output.pitch")]
        for (group, id) in representatives {
            let filter = app.buttons["channel-filter-\(group)"]
            for _ in 0..<6 where !filter.isHittable { groups.swipeLeft() }
            XCTAssertTrue(filter.isHittable, "The \(group) group must be reachable.")
            filter.tap()
            XCTAssertTrue(app.buttons["channel-\(id)"].waitForExistence(timeout: 5))
            if id != "accel.x" { XCTAssertFalse(app.buttons["channel-accel.x"].exists) }
        }
        for _ in 0..<6 where !app.buttons["channel-filter-All"].isHittable { groups.swipeRight() }
        app.buttons["channel-filter-All"].tap()
        search(app, for: "signal-no-matches-123")
        XCTAssertFalse(app.buttons["channel-accel.x"].exists)
        XCTAssertFalse(app.buttons["channel-touch.x"].exists)
        screenshot(app, "16-channels-empty-search-and-restrictions")
        search(app, for: "Acceleration X")
        let row = app.buttons["channel-accel.x"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let inspector = app.scrollViews["inspector-scroll"]
        tap(app.buttons["inspector-enable-motion"], scrolling: inspector)
        XCTAssertTrue(app.buttons["inspector-stop-motion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Source status: UNAVAILABLE"].exists)
        app.buttons["inspector-stop-motion"].tap()
        XCTAssertTrue(app.buttons["inspector-enable-motion"].waitForExistence(timeout: 5))
        tap(app.buttons["inspector-patch-menu"], scrolling: inspector)
        menuItem(app, "Phosphor hue").tap()
        screenshot(app, "17-inspector-source-lifecycle-and-patch-shortcut")
        app.buttons["Done"].tap()
        app.tabBars.buttons["Patch"].tap()
        let route = app.switches["patch-enable-accel.x-Phosphor hue"]
        tapToReveal(route, scrolling: app.scrollViews["patch-scroll"], anchor: app.descendants(matching: .any)["patch-route-accel.x-Phosphor hue"])
        assertSwitch(route, hasValue: "1", in: app)
        tap(app.buttons["patch-remove-accel.x-Phosphor hue"], scrolling: app.scrollViews["patch-scroll"])
        XCTAssertFalse(route.exists)
    }

    @MainActor
    func testAllPatchPresetsDestinationsDuplicateProtectionAndOutputControls() {
        executionTimeAllowance = 600
        let app = launch(arguments: ["-demo", "-patch"])
        let scroll = app.scrollViews["patch-scroll"]
        let presets = app.scrollViews["patch-presets"]
        tapToReveal(presets, scrolling: scroll, toward: .top)
        for (name, source, target) in [("Motion → field", "motion.intensity", "Field energy"), ("Sound → orbit", "mic.rms", "Field energy"), ("Touch → tone", "touch.x", "Tone pitch")] {
            tapToReveal(presets, scrolling: scroll, toward: .top)
            let preset = app.buttons["patch-preset-\(name)"]
            for _ in 0..<4 where !preset.isHittable { presets.swipeLeft() }
            preset.tap()
            let route = app.switches["patch-enable-\(source)-\(target)"]
            tapToReveal(route, scrolling: scroll, anchor: app.descendants(matching: .any)["patch-route-\(source)-\(target)"])
            assertSwitch(route, hasValue: "1", in: app)
            screenshot(app, "18-preset-\(source)")
        }
        tap(app.buttons["patch-source-picker"], scrolling: scroll, toward: .top)
        search(app, for: "signal-no-matches-123")
        XCTAssertFalse(app.buttons["patch-input-touch.x"].exists)
        search(app, for: "Touch X")
        app.buttons["patch-input-touch.x"].tap()
        for target in ["Field energy", "Orbit speed", "Phosphor hue", "Tone pitch", "Tone level", "Haptic pulse"] {
            selectPatchDestination(target, in: app, scrolling: scroll)
            let connect = app.buttons["patch-connect"]
            tapToReveal(connect, scrolling: scroll, toward: .top)
            if target == "Tone pitch" {
                XCTAssertFalse(connect.isEnabled, "The Touch preset already connects this pair.")
                XCTAssertEqual(connect.label, "Already connected")
            } else {
                XCTAssertTrue(connect.isEnabled)
                connect.tap()
                XCTAssertFalse(connect.isEnabled, "The newly connected pair must prevent a duplicate.")
                let route = app.switches["patch-enable-touch.x-\(target)"]
                tapToReveal(route, scrolling: scroll, anchor: app.descendants(matching: .any)["patch-route-touch.x-\(target)"])
                assertSwitch(route, hasValue: "1", in: app)
                tap(app.buttons["patch-inspect-touch.x-\(target)"], scrolling: scroll)
                XCTAssertTrue(app.navigationBars["Touch X"].waitForExistence(timeout: 5))
                app.buttons["Done"].tap()
                tap(app.buttons["patch-remove-touch.x-\(target)"], scrolling: scroll)
                XCTAssertFalse(route.exists)
            }
        }
        let sound = app.switches["patch-sound-toggle"]
        tap(sound, scrolling: scroll)
        assertSwitch(sound, hasValue: "1", in: app)
        let haptics = app.switches["patch-haptics-toggle"]
        tap(haptics, scrolling: scroll)
        assertSwitch(haptics, hasValue: "1", in: app)
        XCTAssertTrue(app.staticTexts["Haptic hardware is unavailable in this runtime."].exists)
        screenshot(app, "19-patch-output-controls-enabled")
        app.buttons["capture-transport"].tap()
        XCTAssertTrue(app.staticTexts["Capture is paused, so physical outputs are stopped. Enabled outputs resume with capture."].exists)
        assertSwitch(sound, hasValue: "1", in: app)
        app.buttons["capture-transport"].tap()
        tapControl(sound)
        tapControl(haptics)
        assertSwitch(sound, hasValue: "0", in: app)
        assertSwitch(haptics, hasValue: "0", in: app)
        screenshot(app, "20-patch-output-controls-muted")
    }

    @MainActor
    func testAllSensorAccessControlsDemoLocksSharedOutputsAndUWBValidation() {
        executionTimeAllowance = 600
        let app = launch()
        app.buttons["source-menu"].tap()
        menuItem(app, "Sensor access").tap()
        let list = app.descendants(matching: .any)["sensor-access-list"]
        for sensor in ["motion", "barometer", "steps", "location", "microphone", "camera", "bluetooth", "proximity"] {
            let control = app.switches["sensor-\(sensor)"]
            if sensor == "motion" {
                tapToReveal(control, scrolling: list)
                screenshot(app, "21a-sensor-motion-before-enable")
                accessibilityEvidence(control, in: app, named: "sensor-motion-before-enable")
            }
            tap(control, scrolling: list)
            if sensor == "location" || sensor == "microphone" { acceptSensorPermissionIfPresent(app) }
            assertSwitch(control, hasValue: "1", in: app)
            tapControl(control)
            assertSwitch(control, hasValue: "0", in: app)
        }
        tap(app.buttons["sensor-nfc"], scrolling: list)
        XCTAssertTrue(app.navigationBars["Sensor access"].exists)
        tap(app.buttons["sensor-peer"], scrolling: list)
        XCTAssertTrue(app.navigationBars["UWB peer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["peer-prepare"].isEnabled)
        XCTAssertFalse(app.buttons["peer-connect"].isEnabled)
        let peerScroll = app.scrollViews["peer-scroll"]
        let token = app.textViews["peer-token"].exists ? app.textViews["peer-token"] : app.textFields["peer-token"]
        tap(token, scrolling: peerScroll)
        token.typeText("invalid-token")
        let dismissKeyboard = app.buttons["peer-dismiss-keyboard"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5))
        dismissKeyboard.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 5), .completed)
        XCTAssertEqual(token.value as? String, "invalid-token", "Dismissing the keyboard must preserve the entered peer token.")
        tap(app.buttons["peer-connect"], scrolling: peerScroll)
        let error = app.staticTexts["Paste the complete base64 discovery token from the other phone."].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        screenshot(app, "21-uwb-unsupported-and-invalid-token")
        tap(app.buttons["peer-stop"], scrolling: peerScroll)
        XCTAssertTrue(app.staticTexts["Session stopped. Prepare and exchange new tokens to range again."].waitForExistence(timeout: 5))
        app.navigationBars["UWB peer"].buttons["Done"].tap()
        let sound = app.switches["sensor-sound-toggle"]
        let haptics = app.switches["sensor-haptics-toggle"]
        tap(sound, scrolling: list)
        tap(haptics, scrolling: list)
        assertSwitch(sound, hasValue: "1", in: app)
        assertSwitch(haptics, hasValue: "1", in: app)
        tap(app.switches["sensor-demo-toggle"], scrolling: list, toward: .top)
        let motion = app.switches["sensor-motion"]
        tapToReveal(motion, scrolling: list, requiringHittable: false)
        XCTAssertTrue(motion.exists)
        XCTAssertFalse(motion.isEnabled)
        tapToReveal(app.buttons["sensor-peer"], scrolling: list, requiringHittable: false)
        XCTAssertTrue(app.buttons["sensor-peer"].exists)
        XCTAssertFalse(app.buttons["sensor-peer"].isEnabled)
        screenshot(app, "22-sensor-demo-access-locks")
        tap(app.switches["sensor-demo-toggle"], scrolling: list, toward: .top)
        tapToReveal(motion, scrolling: list)
        XCTAssertTrue(motion.exists)
        XCTAssertTrue(motion.isEnabled)
        app.navigationBars["Sensor access"].buttons["Done"].tap()
        app.tabBars.buttons["Patch"].tap()
        let patchScroll = app.scrollViews["patch-scroll"]
        tapToReveal(app.switches["patch-sound-toggle"], scrolling: patchScroll)
        assertSwitch(app.switches["patch-sound-toggle"], hasValue: "1", in: app)
        assertSwitch(app.switches["patch-haptics-toggle"], hasValue: "1", in: app)
        tapControl(app.switches["patch-sound-toggle"])
        tapControl(app.switches["patch-haptics-toggle"])
    }

    @MainActor
    func testFieldQuickStartFeaturedSelectionAndInspector() {
        let app = launch()
        let scroll = app.scrollViews["field-scroll"]
        tap(app.buttons["enable-motion"], scrolling: scroll)
        XCTAssertFalse(app.buttons["enable-motion"].exists)
        app.buttons["source-menu"].tap()
        menuItem(app, "Sensor access").tap()
        tapControl(app.switches["sensor-motion"])
        app.buttons["Done"].tap()
        tap(app.buttons["try-demo"], scrolling: scroll)
        XCTAssertTrue(app.staticTexts["A PLAYABLE DEMO OF THE INSTRUMENT"].exists)
        tap(app.buttons["inspect-selected"], scrolling: scroll)
        XCTAssertTrue(app.navigationBars["Movement energy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Source status: DEMO"].exists)
        app.buttons["Done"].tap()
        let featured = app.scrollViews["field-featured"]
        tapToReveal(app.buttons["select-motion.intensity"], scrolling: scroll)
        for (id, name) in [("motion.intensity", "Movement energy"), ("mag.total", "Field magnitude"), ("pressure", "Air pressure"), ("mic.rms", "Microphone level"), ("ble.rssi", "Strongest BLE signal"), ("location.speed", "Ground speed"), ("device.battery", "Battery charge"), ("touch.x", "Touch X")] {
            let control = app.buttons["select-\(id)"]
            for _ in 0..<5 where !control.isHittable { featured.swipeLeft() }
            control.tap()
            // The selected readout stays beside the featured rail. The orbital
            // canvas may be outside the accessibility viewport after revealing it.
            XCTAssertTrue(app.staticTexts[name.uppercased()].waitForExistence(timeout: 3), "Selecting \(name) must update the visible readout.")
        }
        // Demo generates sensor channels; interaction telemetry still comes
        // from real input. Exercise it instead of assigning it DEMO provenance.
        let field = app.descendants(matching: .any)["Interactive signal field"]
        tapToReveal(field, scrolling: scroll, toward: .top)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65))
            .press(forDuration: 0.15, thenDragTo: field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)))
        tap(app.buttons["inspect-selected"], scrolling: scroll)
        XCTAssertTrue(app.navigationBars["Touch X"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Source status: LIVE"].exists)
        screenshot(app, "23-field-featured-selection-inspector")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Field"].isSelected)
    }

    @MainActor
    func testExternalSettingsAndDocumentationHandoffsReturnToCurrentSheet() {
        executionTimeAllowance = 600
        let app = launch(arguments: ["-channels"])
        search(app, for: "Movement energy")
        let channel = app.buttons["channel-motion.intensity"]
        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        channel.tap()
        XCTAssertTrue(app.navigationBars["Movement energy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Source status: UNAVAILABLE"].exists)
        tap(app.buttons["Settings"], scrolling: app.scrollViews["inspector-scroll"])
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "The inspector's Settings action must open the system Settings app.")
        screenshot(settings, "24-inspector-system-settings-handoff")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["Movement energy"].waitForExistence(timeout: 5), "Returning must preserve the channel inspector.")
        screenshot(app, "25-inspector-return-from-settings")
        app.buttons["Done"].tap()
        // Native search replaces the navigation toolbar while it is active.
        let closeSearch = app.buttons["Close"]
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5))
        closeSearch.tap()
        XCTAssertTrue(app.buttons["source-menu"].waitForExistence(timeout: 5))
        app.buttons["source-menu"].tap()
        menuItem(app, "About this instrument").tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        tap(app.links["Apple sensor and privacy documentation"], scrolling: app.scrollViews["about-scroll"])
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "The documentation link must open the system browser.")
        // Safari can present first-launch setup. Foreground handoff is mandatory;
        // inspect the destination whenever its native address field is available.
        let address = safari.textFields["Address"].exists ? safari.textFields["Address"] : safari.textFields["URL"]
        if address.exists {
            let destination = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "developer.apple.com"), object: address)
            XCTAssertEqual(XCTWaiter.wait(for: [destination], timeout: 10), .completed, "The browser address must identify Apple's documentation domain.")
        }
        screenshot(safari, "26-about-apple-documentation-browser-handoff")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5), "Returning must preserve the About sheet.")
        screenshot(app, "27-about-return-from-browser")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Channels"].isSelected)
    }

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        currentApplication = app
        app.launchArguments = arguments
        app.launchEnvironment["TELEMETRY_UI_TEST"] = "1"
        app.launchEnvironment["TELEMETRY_TEST_HOST"] = "0"
        // XCTest may interrupt a failed test through Objective-C before Swift
        // defer executes. Its registered teardown still runs for that failure.
        addTeardownBlock {
            await MainActor.run {
                if app.state != .notRunning { app.terminate() }
            }
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Field"].waitForExistence(timeout: 15), "The real app UI must load; a unit-test blank host is not a successful launch.")
        return app
    }

    @MainActor
    private func search(_ app: XCUIApplication, for text: String) {
        let field = app.searchFields.firstMatch
        if !field.isHittable {
            if app.buttons["Search"].isHittable { app.buttons["Search"].tap() }
            else { app.scrollViews.firstMatch.swipeDown() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            let clear = field.buttons["Clear text"]
            if clear.exists && clear.isHittable {
                clear.tap()
            } else {
                // A tap can put the caret in the middle of existing input. Select
                // all instead of deleting backwards from an unknown caret position.
                field.press(forDuration: 1)
                let selectAll = app.buttons["Select All"]
                if !selectAll.exists {
                    let select = app.buttons["Select"]
                    if select.exists { select.tap() }
                }
                XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Existing search input must expose Clear text or Select All.")
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
        }
        field.typeText(text)
        let query = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        let result = XCTWaiter.wait(for: [query], timeout: 5)
        if result != .completed {
            screenshot(app, "search-input-failed")
            accessibilityEvidence(field, in: app, named: "search-input-failed")
        }
        XCTAssertEqual(result, .completed, "Search must contain exactly \(text), rather than a partial replacement.")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
    }

    @MainActor
    private func acceptSensorPermissionIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = app.alerts.firstMatch.waitForExistence(timeout: 1) ? app.alerts.firstMatch : springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
        XCTFail("The permission alert did not expose a supported Allow action: \(alert.label)")
    }

    @MainActor
    private func dismissShareSheet(_ app: XCUIApplication) {
        let shareAction = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@", "Copy", "Save to Files")).firstMatch
        let close = app.buttons["Close"].firstMatch
        if close.exists && close.isHittable { close.tap() }
        else if app.buttons["Cancel"].firstMatch.isHittable { app.buttons["Cancel"].firstMatch.tap() }
        else {
            let activity = app.otherElements["ActivityListView"]
            XCTAssertTrue(activity.exists, "The native activity container must be present before dismissal.")
            // iOS 27 presents this compact activity panel without a Sheet or
            // Close button. Its outside-tap dismissal keeps the source intact.
            let heading = app.staticTexts["A session in signals."]
            XCTAssertTrue(heading.exists)
            heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let actionsGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: shareAction)
        let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: app.buttons["source-menu"])
        let result = XCTWaiter.wait(for: [actionsGone, menuReady], timeout: 5)
        if result != .completed { screenshot(app, "share-sheet-dismissal-failed") }
        XCTAssertEqual(result, .completed, "The share actions must disappear and the source menu must become tappable after dismissal.")
    }

    @MainActor
    private func selectPatchDestination(_ target: String, in app: XCUIApplication, scrolling scroll: XCUIElement) {
        let picker = app.buttons["patch-target-picker"]
        tap(picker, scrolling: scroll, toward: .top)
        let item = app.buttons["patch-destination-\(target)"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "The native destination menu must expose \(target).")
        var completed = false
        for _ in 0..<2 {
            // Native menus can reposition as the presenting control settles.
            // A missed first tap must not turn the following scroll into a
            // drag through the menu's other destination choices.
            var previousFrame = CGRect.zero
            var stableSince = ProcessInfo.processInfo.systemUptime
            let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard item.exists, item.isHittable else { return false }
                let frame = item.frame
                let now = ProcessInfo.processInfo.systemUptime
                let moved = abs(frame.minX - previousFrame.minX) > 1 || abs(frame.minY - previousFrame.minY) > 1 || abs(frame.width - previousFrame.width) > 1 || abs(frame.height - previousFrame.height) > 1
                if moved { previousFrame = frame; stableSince = now }
                return !frame.isEmpty && now - stableSince >= 0.4
            }, object: item)
            let stability = XCTWaiter.wait(for: [stable], timeout: 12)
            if stability != .completed {
                screenshot(app, "destination-stability-failed-\(target)")
                accessibilityEvidence(item, in: app, named: "destination-stability-failed-\(target)")
            }
            XCTAssertEqual(stability, .completed, "The destination menu item must settle before selection.")
            // Give the native menu a human-length touch. The failure recording
            // showed XCTest's 50 ms tap at the correct row center with no commit.
            item.press(forDuration: 0.15)
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Destination: \(target)"), object: picker)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item)
            completed = XCTWaiter.wait(for: [selected, dismissed], timeout: 3) == .completed
            if completed { break }
            // Retry only a still-open menu; a wrong committed choice is a real
            // failure and must be preserved rather than overwritten.
            if !item.exists { break }
        }
        if !completed {
            screenshot(app, "destination-selection-failed-\(target)")
            accessibilityEvidence(picker, in: app, named: "destination-selection-failed-\(target)")
        }
        XCTAssertTrue(completed, "Choosing \(target) must update the composer and dismiss the menu before scrolling or connecting.")
    }

    @MainActor
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 3) { return button }
        let toggle = app.switches[label]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Missing source menu item: \(label)")
        return toggle
    }

    @MainActor
    private func tap(_ element: XCUIElement, scrolling scroll: XCUIElement, toward edge: ScrollEdge = .bottom, anchor: XCUIElement? = nil) {
        tapToReveal(element, scrolling: scroll, toward: edge, anchor: anchor)
        tapControl(element)
    }

    @MainActor
    private func tapControl(_ element: XCUIElement) {
        if element.elementType == .switch && element.frame.width > 90 {
            // SwiftUI can expose the label and switch as one wide accessibility
            // element. Its geometric center then lands on the label. The native
            // switch remains at the trailing edge of that observed element frame.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        } else {
            element.tap()
        }
    }

    @MainActor
    private func adjustSlider(_ slider: XCUIElement, to position: Double, range: ClosedRange<Double>, expected: String) {
        var gesturePosition = position
        for _ in 0..<4 {
            // XCTest emits a thumb drag, not a value assignment. Short native
            // tracks can land a step away. Each trial descends from a verified
            // upper endpoint, avoiding direction-dependent correction swings.
            slider.adjust(toNormalizedSliderPosition: 1)
            var endpoint = slider.value as? String ?? ""
            var endpointNumber = Double(endpoint.split(separator: " ").first ?? "")
            var endpointValue = endpointNumber.map { expected.contains("%") ? $0 / 100 : $0 }
            if let value = endpointValue, value < range.upperBound {
                // The native automation gesture can stop at 95% on a short
                // track. Drag the actual near-end thumb past the track edge.
                let frame = slider.frame
                let origin = slider.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: frame.width - 16, dy: frame.height / 2))
                    .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: frame.width + 16, dy: frame.height / 2)), withVelocity: .slow, thenHoldForDuration: 0)
                endpoint = slider.value as? String ?? ""
                endpointNumber = Double(endpoint.split(separator: " ").first ?? "")
                endpointValue = endpointNumber.map { expected.contains("%") ? $0 / 100 : $0 }
            }
            XCTAssertEqual(endpointValue, range.upperBound, "The real slider must reach its upper endpoint before calibration.")
            // The accessibility frame includes the thumb's half-width at both
            // ends. Move between actual thumb centers, rather than requesting
            // a percentage of that wider frame through XCTest's approximation.
            let frame = slider.frame
            let origin = slider.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: frame.width - 16, dy: frame.height / 2))
                .press(forDuration: 0.15, thenDragTo: origin.withOffset(CGVector(dx: 16 + (frame.width - 32) * gesturePosition, dy: frame.height / 2)), withVelocity: .slow, thenHoldForDuration: 0)
            let readout = slider.value as? String ?? ""
            if readout == expected { return }
            guard let number = Double(readout.split(separator: " ").first ?? "") else { break }
            let value = expected.contains("%") ? number / 100 : number
            let observed = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let corrected = min(1, max(0, gesturePosition + position - observed))
            if abs(corrected - gesturePosition) < 0.001 { break }
            gesturePosition = corrected
        }
        if let app = currentApplication {
            screenshot(app, "slider-value-failed-\(slider.identifier)")
            accessibilityEvidence(slider, in: app, named: "slider-value-failed-\(slider.identifier)")
        }
        XCTAssertEqual(slider.value as? String, expected, "The real slider must reach the requested stepped value.")
    }

    @MainActor
    private func assertSwitch(_ control: XCUIElement, hasValue expected: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Resolve a new remote accessibility snapshot on each predicate evaluation.
        let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: control)
        let result = XCTWaiter.wait(for: [state], timeout: 5)
        if result != .completed {
            screenshot(app, "switch-state-failed-\(control.identifier)-expected-\(expected)")
            accessibilityEvidence(control, in: app, named: "switch-state-failed-\(control.identifier)")
        }
        XCTAssertEqual(result, .completed, "\(control.identifier) must reach \(expected); current value is \(String(describing: control.value)).", file: file, line: line)
    }

    @MainActor
    private func accessibilityEvidence(_ control: XCUIElement, in app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(string: "Control:\n\(control.debugDescription)\n\nApp:\n\(app.debugDescription)")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tapToReveal(_ element: XCUIElement, scrolling scroll: XCUIElement, toward edge: ScrollEdge = .bottom, anchor: XCUIElement? = nil, requiringHittable: Bool = true) {
        // Native chrome stays fixed during a reveal; refresh it for each new
        // action/sheet, rather than issuing the same remote queries per swipe.
        let viewport = visibleViewport(of: scroll)
        for attempt in 0..<12 {
            let exists = element.exists
            let targetFrame = exists ? element.frame : .zero
            // An element can be partly hittable while the trailing native Switch
            // hit point is still clipped. Bring the actual control center inside.
            let hitX = exists && element.elementType == .switch && targetFrame.width > 90 ? targetFrame.minX + targetFrame.width * 0.9 : targetFrame.midX
            let hitPoint = CGPoint(x: hitX, y: targetFrame.midY)
            if exists && !targetFrame.isEmpty && viewport.contains(hitPoint) && (!requiringHittable || element.isHittable) { return }
            if attempt == 3, !element.exists, let app = currentApplication {
                revealEvidence(element, scrolling: scroll, in: app, named: "reveal-missing-after-three-scrolls")
            }
            // Route controls sit above their dials. Returning to Invert or Remove
            // after adjusting a lower slider must be able to scroll back up.
            let anchorFrame: CGRect
            if let anchor, anchor.exists { anchorFrame = anchor.frame }
            else { anchorFrame = .zero }
            if !exists && !anchorFrame.isEmpty && viewport.contains(anchorFrame) {
                // A fully materialized container must expose its real child ID.
                // Scrolling elsewhere cannot repair a missing child identifier.
                if element.waitForExistence(timeout: 1) { continue }
                break
            }
            if !targetFrame.isEmpty && !viewport.isEmpty {
                scrollForReveal(scroll, upward: targetFrame.midY >= viewport.midY, viewport: viewport)
            } else if !anchorFrame.isEmpty && anchorFrame.minY < viewport.minY {
                scrollForReveal(scroll, upward: false, viewport: viewport)
            } else if !anchorFrame.isEmpty && anchorFrame.maxY > viewport.maxY {
                scrollForReveal(scroll, upward: true, viewport: viewport)
            } else if edge == .top {
                // Lazy rows above the viewport have no frame. Their known
                // position must guide the search instead of seven wrong swipes.
                scrollForReveal(scroll, upward: false, viewport: viewport)
            } else {
                scrollForReveal(scroll, upward: true, viewport: viewport)
            }
        }
        if let app = currentApplication {
            revealEvidence(element, scrolling: scroll, in: app, named: "reveal-failed")
        }
        let frame = element.exists ? element.frame : .zero
        let visible = !frame.isEmpty && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(element.exists && visible && (!requiringHittable || element.isHittable), "The requested control must be visible\(requiringHittable ? " and tappable" : "").")
    }

    @MainActor
    private func visibleViewport(of scroll: XCUIElement) -> CGRect {
        var viewport = scroll.frame.insetBy(dx: 0, dy: 16)
        guard let app = currentApplication else { return viewport }
        // Modal sheets keep the presenting tab/nav bars in the AX tree. Their
        // covered frames must not clip the sheet's actual visible footer.
        let top = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY + 20 }.max() ?? viewport.minY
        let bottom = app.tabBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.minY - 20 }.min() ?? viewport.maxY
        let keyboardTop = app.keyboards.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.minY - 44 }.min() ?? viewport.maxY
        let minY = max(viewport.minY, top)
        let maxY = min(viewport.maxY, bottom, keyboardTop)
        viewport = CGRect(x: viewport.minX, y: minY, width: viewport.width, height: max(0, maxY - minY))
        return viewport
    }

    @MainActor
    private func scrollForReveal(_ scroll: XCUIElement, upward: Bool, viewport: CGRect) {
        let frame = scroll.frame
        XCTAssertGreaterThan(viewport.height, 80, "A real unobscured scroll viewport is required.")
        // Stay inside the padded content hit region, beside the dial faces.
        // A drag outside SwiftUI's content can miss the ScrollView entirely.
        var x = frame.minX + 34
        let low = viewport.maxY - 24
        var high = viewport.minY + 24
        if !upward {
            // Start on a visible, noninteractive painted panel. A blank gap
            // beside a rounded card can miss scrolling, and the Field canvas
            // deliberately captures drags as telemetry.
            let predicate: NSPredicate?
            if scroll.identifier == "patch-scroll" {
                predicate = NSPredicate(format: "identifier BEGINSWITH %@", "patch-path-")
            } else if scroll.identifier == "field-scroll" {
                predicate = NSPredicate(format: "label ENDSWITH %@", " trace")
            } else { predicate = nil }
            if let predicate {
                let panels = scroll.otherElements.matching(predicate).allElementsBoundByIndex
                var painted: CGRect?
                for panel in panels {
                    let visible = panel.frame.intersection(viewport)
                    guard !visible.isNull, visible.height >= 30, visible.midY < low - 80 else { continue }
                    if let current = painted, current.midY <= visible.midY { continue }
                    painted = visible
                }
                if let painted {
                    x = painted.midX
                    high = painted.midY
                } else {
                    high = min(low - 120, viewport.minY + viewport.height * 0.35)
                }
            }
        }
        let origin = scroll.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x - frame.minX, dy: (upward ? low : high) - frame.minY))
        let end = origin.withOffset(CGVector(dx: x - frame.minX, dy: (upward ? high : low) - frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    }

    private enum ScrollEdge: Equatable { case top, bottom }

    @MainActor
    private func revealEvidence(_ element: XCUIElement, scrolling scroll: XCUIElement, in app: XCUIApplication, named name: String) {
        screenshot(app, name)
        // A missing control has no snapshot to describe. Preserve the query and
        // complete app hierarchy, including actual visible identifiers and types.
        let attachment = XCTAttachment(string: "Target query:\n\(String(describing: element))\n\nScroll:\n\(scroll.debugDescription)\n\nApp:\n\(app.debugDescription)")
        attachment.name = "\(name)-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func firstNumber(in element: XCUIElement) throws -> Double {
        for text in element.staticTexts.allElementsBoundByIndex {
            if let value = Double(text.label) { return value }
        }
        let expression = try NSRegularExpression(pattern: #"(?:^|[,\s])([0-9]+\.[0-9]+)(?:$|[,\s])"#)
        let label = element.label
        let match = try XCTUnwrap(expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: label))
        return try XCTUnwrap(Double(label[range]))
    }
}

import XCTest

/// Separates a broken Simulator accessibility service from instrument behavior.
final class SimulatorAccessibilityTests: XCTestCase {
    @MainActor
    func testSystemSettingsAccessibilityAndNavigation() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        defer { settings.terminate() }
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        let general = settings.buttons["General"]
        if !general.isHittable { settings.swipeUp() }
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.tap()
        XCTAssertTrue(settings.navigationBars["General"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: settings.screenshot())
        attachment.name = "simulator-system-accessibility-smoke"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension SimulatorAccessibilityTests {
    /// Check keyboard automation independently of the simulator's Settings search index.
    @MainActor
    func testSystemSettingsSearchKeyboardInput() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        addTeardownBlock {
            await MainActor.run {
                if settings.state != .notRunning { settings.terminate() }
            }
        }
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        if settings.navigationBars["General"].exists {
            settings.navigationBars.buttons["Settings"].tap()
        }
        let field = settings.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(settings.keyboards.firstMatch.waitForExistence(timeout: 5))
        // iOS can cover its first keyboard with a slide-to-type introduction.
        // Dismiss only that observed, native onboarding control.
        let introduction = settings.buttons["Continue"].firstMatch
        if introduction.exists && introduction.isHittable { introduction.tap() }
        let clear = field.buttons["Clear text"]
        if clear.exists && clear.isHittable { clear.tap() }
        field.typeText("General")
        XCTAssertEqual(field.value as? String, "General")
        let entered = XCTAttachment(screenshot: settings.screenshot())
        entered.name = "settings-keyboard-exact-query"
        entered.lifetime = .keepAlways
        add(entered)
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR value == %@", "", field.placeholderValue ?? "Search"),
            object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed)
        let cleared = XCTAttachment(screenshot: settings.screenshot())
        cleared.name = "settings-keyboard-query-cleared"
        cleared.lifetime = .keepAlways
        add(cleared)
    }
}

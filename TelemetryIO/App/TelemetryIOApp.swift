import SwiftUI

@main struct TelemetryIOApp: App {
    @State private var model = InstrumentModel()
    var body: some Scene {
        WindowGroup {
            if isUnitTestHost {
                Color.clear
            } else {
                RootView(model: model).preferredColorScheme(.dark).tint(IOTheme.mint)
            }
        }
    }
    private var isUnitTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TELEMETRY_TEST_HOST"] == "1" || (environment["XCTestConfigurationFilePath"] != nil && environment["TELEMETRY_UI_TEST"] != "1")
    }
}

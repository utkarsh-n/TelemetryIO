// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TelemetryCore", products: [.library(name: "TelemetryCore", targets: ["TelemetryCore"])], targets: [.target(name: "TelemetryCore"), .testTarget(name: "TelemetryCoreTests", dependencies: ["TelemetryCore"])])

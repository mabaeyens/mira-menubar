// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mira-menubar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiraMenuBar", targets: ["MiraMenuBar"]),
    ],
    targets: [
        // Everything testable without a UI: process supervision, health, first-run.
        .target(name: "MiraSupervisorCore"),
        // SwiftUI app and views only.
        .executableTarget(name: "MiraMenuBar", dependencies: ["MiraSupervisorCore"]),
        .testTarget(name: "MiraSupervisorCoreTests", dependencies: ["MiraSupervisorCore"]),
    ]
)

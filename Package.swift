// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mira-menubar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiraMenuBar", targets: ["MiraMenuBar"]),
    ],
    dependencies: [
        // In-app updates. Pinned to a release; the binary framework is checksummed by SwiftPM.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Everything testable without a UI: process supervision, health, first-run.
        .target(name: "MiraSupervisorCore"),
        // SwiftUI app and views only.
        .executableTarget(
            name: "MiraMenuBar",
            dependencies: [
                "MiraSupervisorCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(name: "MiraSupervisorCoreTests", dependencies: ["MiraSupervisorCore"]),
    ]
)

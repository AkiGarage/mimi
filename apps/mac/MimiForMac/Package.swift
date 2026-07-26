// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MimiForMac",
    defaultLocalization: "en",
    // SwiftPM exposes major macOS platform versions only. The implementation
    // gates Process Tap at its documented macOS 14.2 API boundary.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MimiForMac", targets: ["MimiForMac"]),
        .executable(name: "MimiForMacDebug", targets: ["MimiForMacDebug"])
    ],
    targets: [
        .target(
            name: "MimiForMac",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .executableTarget(name: "MimiForMacDebug", dependencies: ["MimiForMac"]),
        .testTarget(name: "MimiForMacTests", dependencies: ["MimiForMac"])
    ]
)

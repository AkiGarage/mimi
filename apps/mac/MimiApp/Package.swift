// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MimiApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MimiApp", targets: ["MimiApp"]),
        .library(name: "MimiAppCore", targets: ["MimiAppCore"])
    ],
    targets: [
        .target(
            name: "MimiAppCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "MimiApp",
            dependencies: ["MimiAppCore"]
        ),
        .testTarget(
            name: "MimiAppCoreTests",
            dependencies: ["MimiAppCore"]
        ),
        .testTarget(
            name: "MimiAppTests",
            dependencies: ["MimiApp", "MimiAppCore"]
        )
    ]
)

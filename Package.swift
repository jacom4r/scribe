// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"]),
        .executable(name: "Scribe", targets: ["Scribe"]),
        .executable(name: "scribe-cli", targets: ["scribe-cli"]),
    ],
    targets: [
        .target(
            name: "ScribeCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(name: "Scribe", dependencies: ["ScribeCore"]),
        .executableTarget(name: "scribe-cli", dependencies: ["ScribeCore"]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
    ]
)

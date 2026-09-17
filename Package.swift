// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"]),
        .library(name: "ScribeTranscription", targets: ["ScribeTranscription"]),
        .executable(name: "Scribe", targets: ["Scribe"]),
        .executable(name: "scribe-cli", targets: ["scribe-cli"]),
    ],
    dependencies: [
        // Exact pin: FluidAudio moves fast. `traits: []` opts out of the
        // NemoTextProcessing binary, which only TTS uses.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7", traits: []),
    ],
    targets: [
        .target(
            name: "ScribeCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "ScribeTranscription",
            dependencies: [
                "ScribeCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "Scribe", dependencies: ["ScribeCore", "ScribeTranscription"]),
        .executableTarget(name: "scribe-cli", dependencies: ["ScribeCore", "ScribeTranscription"]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
    ]
)

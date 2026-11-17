// swift-tools-version: 6.2
// Builds the app's executable; build.sh wraps it into "Claude Whisper.app".
import PackageDescription

let package = Package(
    name: "ClaudeWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Runs the Parakeet speech model for Note Taker. Pinned to one release; no traits, so only
        // speech recognition is compiled in and no prebuilt binary is downloaded.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeWhisper",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

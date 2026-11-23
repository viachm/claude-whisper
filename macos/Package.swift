// swift-tools-version: 6.2
// Builds the app's executable; build.sh wraps it into "Claude Whisper.app".
import PackageDescription

let package = Package(
    name: "ClaudeWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Runs the Parakeet speech model for Note Taker and tells the voices on a call apart. Pinned
        // to one release; only the Diarizer trait (Swift source), so no prebuilt binary is downloaded.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
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

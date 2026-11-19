// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, testable logic: classification, cue grammar, trackers, key
        // interpretation, and sound synthesis. No AppKit, no Accessibility.
        .target(name: "PulseCore"),
        // The menu-bar app: event taps, Accessibility queries, haptics, audio.
        .executableTarget(
            name: "Pulse",
            dependencies: ["PulseCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
    ]
)

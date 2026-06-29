// swift-tools-version:5.9
import PackageDescription

// MulberryBench — the open, run-it-yourself AI benchmark behind Mulberry's
// on-device capability check. Pure Foundation + URLSession, no dependencies,
// no telemetry. Local runs need no key and make no network calls.
let package = Package(
    name: "MulberryBench",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "mulberry-bench",
            path: "Sources/mulberry-bench"
        )
    ]
)

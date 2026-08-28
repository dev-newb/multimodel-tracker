// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MultimodelTracker",
    // The bundle already refuses to launch below 14 (LSMinimumSystemVersion),
    // so the package target matching it costs nothing and unlocks the 13.3+
    // SwiftUI API (scrollBounceBehavior) without availability scaffolding.
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MultimodelTracker",
            path: "Sources/MultimodelTracker"
        )
    ]
)

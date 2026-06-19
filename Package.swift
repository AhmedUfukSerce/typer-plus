// swift-tools-version:5.9
// Swift 5 language mode (default for tools 5.9) is deliberate: this is a
// single-main-thread, timer/callback-driven menu-bar agent, and Swift 6 strict
// concurrency adds friction with no benefit here (same rationale as Cursor+).
import PackageDescription

let package = Package(
    name: "TyperPlus",
    platforms: [.macOS(.v14)],
    targets: [
        // The app.
        .executableTarget(
            name: "TyperPlus",
            path: "Sources/TyperPlus",
            resources: [
                .copy("Resources/Fonts")   // bundled Inter faces (registered at launch)
            ]
        ),
        // De-risk harness: proves CGEvent injection is seen as isTrusted and that
        // the Google Docs canvas ingests it, BEFORE relying on the full app.
        .executableTarget(
            name: "InjectTest",
            path: "Sources/InjectTest"
        ),
    ]
)

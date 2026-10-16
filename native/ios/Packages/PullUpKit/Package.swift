// swift-tools-version: 6.0
import PackageDescription

// PullUpKit holds everything except the app shell. Layering (lower never imports higher):
//
//   PullUpDomain     value types, rules, units          Foundation only
//   PullUpTelemetry  GPS filtering + drive statistics   Foundation only
//   PullUpData       repositories, Supabase, local store
//   PullUpLocation   Core Location recorder (iOS)
//   PullUpDesign     design system ("Cluster")
//   PullUpFeatures   SwiftUI screens and view models
//
// Domain and Telemetry stay platform-neutral so they run under `swift test`
// on macOS in seconds, and so the rules can be ported verbatim to Kotlin.
let package = Package(
    name: "PullUpKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PullUpDomain", targets: ["PullUpDomain"]),
        .library(name: "PullUpTelemetry", targets: ["PullUpTelemetry"]),
        .library(name: "PullUpData", targets: ["PullUpData"]),
        .library(name: "PullUpLocation", targets: ["PullUpLocation"]),
        .library(name: "PullUpDesign", targets: ["PullUpDesign"]),
        .library(name: "PullUpFeatures", targets: ["PullUpFeatures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", .upToNextMajor(from: "2.20.0")),
    ],
    targets: [
        .target(name: "PullUpDomain"),
        .target(name: "PullUpTelemetry", dependencies: ["PullUpDomain"]),
        .target(
            name: "PullUpData",
            dependencies: [
                "PullUpDomain",
                "PullUpTelemetry",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .target(name: "PullUpLocation", dependencies: ["PullUpDomain", "PullUpTelemetry"]),
        .target(name: "PullUpDesign", dependencies: ["PullUpDomain"]),
        .target(
            name: "PullUpFeatures",
            dependencies: ["PullUpDomain", "PullUpTelemetry", "PullUpData", "PullUpLocation", "PullUpDesign"]
        ),
        .testTarget(name: "PullUpDomainTests", dependencies: ["PullUpDomain"]),
        .testTarget(name: "PullUpTelemetryTests", dependencies: ["PullUpTelemetry"]),
        .testTarget(name: "PullUpDataTests", dependencies: ["PullUpData"]),
    ],
    swiftLanguageModes: [.v6]
)

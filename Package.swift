// swift-tools-version: 6.0

import PackageDescription

// SwiftPM only reads a manifest at a repository root, so this is what lets
// another repository (the iOS app) depend on SolisHubKit by Git URL and tag.
// The menu bar keeps depending on ../SolisHubKit by path; both manifests build
// the same sources, so there is one copy of the code.
let package = Package(
    name: "solis-tools",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "SolisHubKit", targets: ["SolisHubKit"]),
    ],
    targets: [
        .target(name: "SolisHubKit", path: "SolisHubKit/Sources/SolisHubKit"),
    ]
)

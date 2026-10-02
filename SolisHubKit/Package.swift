// swift-tools-version: 6.0

import PackageDescription

// Foundation and Network only: the menu bar and the iOS app both depend on
// this, and neither should inherit a third-party dependency from it.
let package = Package(
    name: "SolisHubKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "SolisHubKit", targets: ["SolisHubKit"]),
    ],
    targets: [
        .target(name: "SolisHubKit"),
        .testTarget(name: "SolisHubKitTests", dependencies: ["SolisHubKit"]),
    ]
)

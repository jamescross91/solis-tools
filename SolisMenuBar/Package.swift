// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SolisMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SolisMenuBar", targets: ["SolisMenuBar"]),
    ],
    targets: [
        .executableTarget(name: "SolisMenuBar"),
    ]
)

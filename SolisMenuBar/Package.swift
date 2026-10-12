// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SolisMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SolisMenuBar", targets: ["SolisMenuBar"]),
    ],
    dependencies: [
        .package(path: "../SolisHubKit"),
    ],
    targets: [
        .executableTarget(
            name: "SolisMenuBar",
            dependencies: [.product(name: "SolisHubKit", package: "SolisHubKit")]
        ),
        .testTarget(
            name: "SolisMenuBarTests",
            dependencies: [
                "SolisMenuBar",
                .product(name: "SolisHubKit", package: "SolisHubKit"),
            ]
        ),
    ]
)

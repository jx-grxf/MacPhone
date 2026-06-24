// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacPhone",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacPhone", targets: ["MacPhone"])
    ],
    targets: [
        .executableTarget(
            name: "MacPhone",
            path: "Sources/MacPhone"
        )
    ]
)

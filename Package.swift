// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Whistle2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Whistle2",
            targets: ["Whistle2"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Whistle2",
            dependencies: []
        ),
        .testTarget(
            name: "Whistle2Tests",
            dependencies: ["Whistle2"]
        )
    ]
)
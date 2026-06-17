// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LANScanner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LANScanner", targets: ["LANScanner"])
    ],
    targets: [
        .executableTarget(
            name: "LANScanner",
            resources: [
                .process("../../Resources")
            ]
        )
    ]
)

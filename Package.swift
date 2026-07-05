// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Backbeat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BackbeatCore", targets: ["BackbeatCore"]),
        .executable(name: "Backbeat", targets: ["Backbeat"]),
        .executable(name: "BackbeatWorkflowSmoke", targets: ["BackbeatWorkflowSmoke"])
    ],
    targets: [
        .target(name: "BackbeatCore"),
        .executableTarget(
            name: "Backbeat",
            dependencies: ["BackbeatCore"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "BackbeatWorkflowSmoke",
            dependencies: ["BackbeatCore"]
        ),
        .testTarget(
            name: "BackbeatCoreTests",
            dependencies: ["BackbeatCore"]
        )
    ]
)

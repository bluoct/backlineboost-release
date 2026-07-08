// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Backbeat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BackbeatCore", targets: ["BackbeatCore"]),
        .library(name: "BackbeatSeparationMLX", targets: ["BackbeatSeparationMLX"]),
        .executable(name: "Backbeat", targets: ["Backbeat"]),
        .executable(name: "BackbeatWorkflowSmoke", targets: ["BackbeatWorkflowSmoke"]),
        .executable(name: "BackbeatSepBench", targets: ["BackbeatSepBench"]),
        .executable(name: "BackbeatLayerParity", targets: ["BackbeatLayerParity"])
    ],
    dependencies: [
        // The compute substrate the custom HTDemucs engine runs on (D1-A: a linked,
        // exactly-pinned package dependency — framework use, G6-compatible). Pinned
        // EXACT because mlx-swift is pre-1.0: upgrades are deliberate and re-gated
        // by BackbeatLayerParity.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.30.6")
    ],
    targets: [
        .target(name: "BackbeatCore"),
        // MLX-only native engine: the purpose-written custom HTDemucs engine (G6 —
        // no vendored source; Backbeat converts Meta's own `.th` in-process). The
        // test target imports only BackbeatCore, so `swift test` needs no MLX/weights
        // at runtime even though `swift build` compiles this target (architecture §2.4).
        .target(
            name: "BackbeatSeparationMLX",
            dependencies: [
                "BackbeatCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift")
            ]
        ),
        .executableTarget(
            name: "Backbeat",
            dependencies: ["BackbeatCore", "BackbeatSeparationMLX"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "BackbeatWorkflowSmoke",
            dependencies: ["BackbeatCore", "BackbeatSeparationMLX"]
        ),
        // Dev-only measurement tool for the native-engine parity/memory gates.
        // Depends on BackbeatSeparationMLX to wire the real `--engine mlx` (Task 7).
        .executableTarget(
            name: "BackbeatSepBench",
            dependencies: ["BackbeatCore", "BackbeatSeparationMLX"]
        ),
        // Dev-only NPY/reference-activation reader shared by the test target and the
        // BackbeatLayerParity harness. Never a dependency of a shipping target.
        .target(name: "BackbeatParityKit"),
        // Dev-only custom-engine layer-parity harness (charter Phase 2): runs the
        // reference input through the custom HTDemucs graph and compares every block
        // against the Phase 0 reference activations. Needs MLX, so it lives outside
        // the test target (architecture §2.4: default `swift test` stays MLX-free
        // at runtime).
        .executableTarget(
            name: "BackbeatLayerParity",
            dependencies: ["BackbeatCore", "BackbeatSeparationMLX", "BackbeatParityKit"]
        ),
        .testTarget(
            name: "BackbeatCoreTests",
            dependencies: ["BackbeatCore", "BackbeatParityKit"]
        )
    ]
)

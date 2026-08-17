// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodingAgentMetrics",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CodingAgentMetricsCore", targets: ["CodingAgentMetricsCore"]),
        .library(name: "CodingAgentMetricsLifecycle", targets: ["CodingAgentMetricsLifecycle"]),
        .executable(name: "CodingAgentMetricsApp", targets: ["CodingAgentMetricsApp"]),
        .executable(name: "CodingAgentMetricsBenchmark", targets: ["CodingAgentMetricsBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(
            name: "CodingAgentMetricsCore",
            resources: [
                .copy("Fixtures"),
            ],
            linkerSettings: [
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "CodingAgentMetricsApp",
            dependencies: ["CodingAgentMetricsCore", "CodingAgentMetricsLifecycle"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "CodingAgentMetricsBenchmark",
            dependencies: ["CodingAgentMetricsCore"]
        ),
        .target(
            name: "CodingAgentMetricsLifecycle",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "CodingAgentMetricsCoreTests",
            dependencies: ["CodingAgentMetricsCore"]
        ),
        .testTarget(
            name: "CodingAgentMetricsLifecycleTests",
            dependencies: ["CodingAgentMetricsLifecycle"]
        ),
        .testTarget(
            name: "CodingAgentMetricsAppTests",
            dependencies: ["CodingAgentMetricsApp", "CodingAgentMetricsCore"]
        ),
    ]
)

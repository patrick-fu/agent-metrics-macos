// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodingAgentMetrics",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CodingAgentMetricsCore", targets: ["CodingAgentMetricsCore"]),
        .executable(name: "CodingAgentMetricsApp", targets: ["CodingAgentMetricsApp"]),
    ],
    targets: [
        .target(
            name: "CodingAgentMetricsCore",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .executableTarget(
            name: "CodingAgentMetricsApp",
            dependencies: ["CodingAgentMetricsCore"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "CodingAgentMetricsCoreTests",
            dependencies: ["CodingAgentMetricsCore"]
        ),
    ]
)

import Foundation
import Testing

struct ReleaseArtifactIntegrationTests {
    @Test func localDMGContainsMountableReleaseBundleWithCompatibleMetadata() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-dmg-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let buildDirectory = temporaryDirectory.appendingPathComponent("build", isDirectory: true)
        let scratchDirectory = temporaryDirectory.appendingPathComponent("scratch", isDirectory: true)
        let dmgDirectory = temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
        let build = try Self.runDMGBuilder(
            buildDirectory: buildDirectory,
            scratchDirectory: scratchDirectory,
            dmgDirectory: dmgDirectory
        )
        #expect(build.status == 0, "build-dmg.sh failed: \(build.output)")

        let dmg = dmgDirectory.appendingPathComponent("AgentMetrics-0.2.2.dmg")
        #expect(FileManager.default.fileExists(atPath: dmg.path))

        let mountDirectory = temporaryDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountDirectory, withIntermediateDirectories: true)
        let attachment = try Self.run(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mountDirectory.path, dmg.path]
        )
        #expect(attachment.status == 0, "hdiutil attach failed: \(attachment.output)")
        defer {
            _ = try? Self.run(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", "-quiet", mountDirectory.path]
            )
        }

        let bundle = mountDirectory.appendingPathComponent("Agent Metrics.app", isDirectory: true)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
            format: nil
        ) as? [String: Any]

        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mountDirectory.appendingPathComponent("Applications").path) == "/Applications")
        #expect(plist?["CFBundleName"] as? String == "Agent Metrics")
        #expect(plist?["CFBundleShortVersionString"] as? String == "0.2.2")
        #expect(plist?["CFBundleVersion"] as? String == "7")
        #expect(plist?["CFBundleIdentifier"] as? String == "dev.codingagentmetrics.app")
        #expect(plist?["SUFeedURL"] as? String == "https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml")
        #expect(plist?["SUPublicEDKey"] as? String == "xLcFpTMbuvJVcOJlZyap0OgZ2Tp8dJ1oC/BImxW2TaM=")
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func runDMGBuilder(
        buildDirectory: URL,
        scratchDirectory: URL,
        dmgDirectory: URL
    ) throws -> (status: Int32, output: String) {
        try run(
            executable: "/bin/sh",
            arguments: ["scripts/build-dmg.sh"],
            environment: [
                "CODING_AGENT_METRICS_BUILD_DIR": buildDirectory.path,
                "CODING_AGENT_METRICS_DMG_DIR": dmgDirectory.path,
                "CODING_AGENT_METRICS_SWIFT_BUILD_SCRATCH_PATH": scratchDirectory.path,
            ]
        )
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment additions: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-release-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        return (process.terminationStatus, try String(contentsOf: logURL, encoding: .utf8))
    }
}

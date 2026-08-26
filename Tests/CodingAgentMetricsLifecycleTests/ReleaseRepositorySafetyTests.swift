import Foundation
import Testing

struct ReleaseRepositorySafetyTests {
    @Test func repositoryContainsNoCloudReleaseAutomation() {
        let forbiddenPaths = [
            ".github/workflows",
            ".circleci",
            ".gitlab-ci.yml",
            "azure-pipelines.yml",
            "cloudbuild.yaml",
            ".buildkite",
            ".travis.yml",
            "appveyor.yml",
            "bitrise.yml",
            "Jenkinsfile",
        ]

        for path in forbiddenPaths {
            #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(path).path))
        }
    }

    @Test func localCheckerHasNoPublishingOrCredentialExecutionSeam() throws {
        let executableFiles = [
            "scripts/release-check.sh",
            "Sources/CodingAgentMetricsReleaseCheck/main.swift",
            "Sources/CodingAgentMetricsLifecycle/AppcastReleaseContract.swift",
            "Sources/CodingAgentMetricsLifecycle/ReleaseDryRunChecker.swift",
            "Sources/CodingAgentMetricsLifecycle/ReleasePipelineContract.swift",
        ]
        let forbiddenOperations = [
            "codesign ", "notarytool ", "stapler ", "gh release", "gh api",
            "generate_appcast", "sign_update", "curl ", "wget ", "URLSession", "Process(",
        ]

        for path in executableFiles {
            let contents = try Self.contents(path)
            for operation in forbiddenOperations {
                #expect(!contents.contains(operation))
            }
        }
    }

    @Test func releaseCheckerSourceFixturesAndDocsContainNoSensitiveValues() throws {
        let publicFiles = [
            "scripts/release-check.sh",
            "Sources/CodingAgentMetricsReleaseCheck/main.swift",
            "Sources/CodingAgentMetricsLifecycle/AppcastReleaseContract.swift",
            "Sources/CodingAgentMetricsLifecycle/ReleaseDryRunChecker.swift",
            "Sources/CodingAgentMetricsLifecycle/ReleasePipelineContract.swift",
            "Fixtures/release/public-beta/app-info.plist",
            "Fixtures/release/public-beta/appcast.xml",
            "Fixtures/release/public-beta/inspection.json",
            "docs/release/public-beta-runbook.md",
        ]
        let sensitivePatterns = [
            #"/Users/"#,
            #"/Volumes/"#,
            #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#,
            #"-----BEGIN [^-]*(?:PRIVATE|PUBLIC) KEY-----"#,
            #"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#,
            #"(?i)team(?:\s|-)?id\s*[:=]\s*[A-Z0-9]{10}\b"#,
        ]

        for path in publicFiles {
            let contents = try Self.contents(path)
            for pattern in sensitivePatterns {
                #expect(contents.range(of: pattern, options: .regularExpression) == nil)
            }
        }
    }

    @Test func runbookKeepsStableFeedAfterPublicVerificationAndDocumentsRecovery() throws {
        let runbook = try Self.contents("docs/release/public-beta-runbook.md")
        let orderedMarkers = [
            "**Validate the app.**",
            "**Sign, notarize, and staple the DMG.**",
            "**Create a draft release.**",
            "**Upload and verify the public DMG.**",
            "**Publish the release.**",
            "**Update and publish the stable appcast.**",
            "**Verify the updater.**",
        ]
        let offsets = try orderedMarkers.map { marker in
            try #require(runbook.range(of: marker)?.lowerBound)
        }

        #expect(zip(offsets, offsets.dropFirst()).allSatisfy(<))
        #expect(runbook.contains("higher-build roll-forward"))
        #expect(runbook.contains("promises no database downgrade"))
        #expect(runbook.contains("migration backups"))
        #expect(runbook.contains("source logs"))
        #expect(runbook.contains("Uninstalling the app bundle alone does not delete the telemetry store"))
        #expect(runbook.contains("#27 remains blocked"))
    }

    @Test func appBuilderPlacesTheCoreResourceBundleInContentsResources() throws {
        let script = try Self.contents("scripts/build-app.sh")

        #expect(script.contains("mkdir -p \"$bundle/Contents/Resources\""))
        #expect(script.contains("cp -R \"$core_bundle\" \"$bundle/Contents/Resources/CodingAgentMetrics_CodingAgentMetricsCore.bundle\""))
        #expect(!script.contains("cp -R \"$core_bundle\" \"$bundle/$core_bundle\""))
    }

    @Test func appBuilderCreatesARealPublicBundleWithCompatibleMetadataAndResources() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-build-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputDirectory = temporaryDirectory.appendingPathComponent("output", isDirectory: true)
        let scratchDirectory = temporaryDirectory.appendingPathComponent("scratch", isDirectory: true)
        let build = try Self.runBuildScript(
            outputDirectory: outputDirectory,
            scratchDirectory: scratchDirectory
        )
        #expect(build.status == 0, "build-app.sh failed: \(build.output)")

        let bundle = outputDirectory.appendingPathComponent("release/Agent Metrics.app", isDirectory: true)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
            format: nil
        ) as? [String: Any]

        #expect(FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/CodingAgentMetrics").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/CodingAgentMetrics_CodingAgentMetricsCore.bundle").path))
        #expect(plist?["CFBundleName"] as? String == "Agent Metrics")
        #expect(plist?["CFBundleExecutable"] as? String == "CodingAgentMetrics")
        #expect(plist?["CFBundleIdentifier"] as? String == "dev.codingagentmetrics.app")
        #expect(plist?["SUFeedURL"] as? String == "https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml")
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func runBuildScript(
        outputDirectory: URL,
        scratchDirectory: URL
    ) throws -> (status: Int32, output: String) {
        let temporaryDirectory = outputDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let logURL = temporaryDirectory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["scripts/build-app.sh"]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["CODING_AGENT_METRICS_SWIFT_BUILD_SCRATCH_PATH"] = scratchDirectory.path
        environment["CODING_AGENT_METRICS_BUILD_DIR"] = outputDirectory.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        return (process.terminationStatus, try String(contentsOf: logURL, encoding: .utf8))
    }
}

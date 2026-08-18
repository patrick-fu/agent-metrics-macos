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
}

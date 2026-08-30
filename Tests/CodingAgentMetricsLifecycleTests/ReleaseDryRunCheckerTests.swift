import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

struct ReleaseDryRunCheckerTests {
    @Test func checkedInFixtureUsesOnePublicArtifactContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Fixtures/release/public-beta", isDirectory: true)
        let inspection = try JSONDecoder().decode(
            ReleaseDryRunInspection.self,
            from: Data(contentsOf: fixture.appendingPathComponent("inspection.json"))
        )
        let appcastXML = try String(
            contentsOf: fixture.appendingPathComponent("appcast.xml"),
            encoding: .utf8
        )
        let release = try AppcastReleaseContract.validate(
            appcastXML,
            currentBuild: inspection.currentStableBuild
        )
        let expectedURL = URL(string: "https://downloads.example.invalid/AgentMetrics-0.1.1.dmg")!

        #expect(inspection.artifactFilename == "AgentMetrics-0.1.1.dmg")
        #expect(inspection.publicArtifactURL == expectedURL)
        #expect(release.archiveURL == expectedURL)
        #expect(expectedURL.host?.hasSuffix(".invalid") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(inspection.artifactFilename).path))
    }

    @Test func runbookDocumentsTheRepositoryMigrationWithoutBreakingLegacyClients() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runbook = try String(
            contentsOf: root.appendingPathComponent("docs/release/public-beta-runbook.md"),
            encoding: .utf8
        )
        let orderedSteps = [
            "Back up the deployed legacy Pages content and current stable appcast",
            "Rename the primary repository to `patrick-fu/agent-metrics-macos`",
            "Immediately create the public `patrick-fu/coding-agent-metrics` legacy Pages repository",
            "Deploy the backed-up feed as real XML at `updates/appcast.xml`",
            "Point every enclosure to the matching public Release asset in `agent-metrics-macos`",
            "Require an unauthenticated HTTP 200 response for the legacy feed and every enclosure",
        ]
        let offsets = try orderedSteps.map { step in
            try #require(runbook.range(of: step)?.lowerBound)
        }

        #expect(zip(offsets, offsets.dropFirst()).allSatisfy(<))
        #expect(runbook.contains("not an HTML redirect"))
        #expect(runbook.contains("sacrifices GitHub's automatic repository redirect"))
        #expect(runbook.contains("intentional trade-off to keep old clients upgradeable"))
    }

    @Test func runbookMatchesTheConfiguredProductionKeyGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runbook = try String(
            contentsOf: root.appendingPathComponent("docs/release/public-beta-runbook.md"),
            encoding: .utf8
        )

        #expect(runbook.contains("production-gate=MANUAL issue=#27 reason=validate-SUPublicEDKey-locally"))
    }

    @Test func syntheticFixtureCompletesWithoutCredentialsOrPublication() throws {
        let summary = try ReleaseDryRunChecker.validate(
            ReleaseDryRunInput(
                appPropertyList: Self.appPropertyList(),
                appcastXML: Self.appcastXML,
                artifactByteLength: 42,
                inspection: Self.inspection
            )
        )

        #expect(summary.mode == .syntheticDryRun)
        #expect(summary.finalState == .updaterVerified)
        #expect(summary.completedStages == ReleasePipelineStage.allCases)
    }

    @Test func productionAppAccuratelyReportsTheIssue27KeyGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gate = try ReleaseDryRunChecker.productionGate(
            appPropertyList: Data(
                contentsOf: root.appendingPathComponent("Sources/CodingAgentMetricsApp/Info.plist")
            )
        )

        #expect(gate == .requiresIssue27ManualKeyValidation)
    }

    @Test func aPresentKeyStillRequiresIssue27ManualValidation() throws {
        let values: [String: Any] = ["SUPublicEDKey": "synthetic-public-key-marker"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )

        #expect(
            try ReleaseDryRunChecker.productionGate(appPropertyList: data)
                == .requiresIssue27ManualKeyValidation
        )
    }

    @Test func missingOrInvalidPublicKeyRemainsBlockedByIssue27() throws {
        for invalidValue: Any in ["", " \n\t ", true] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["SUPublicEDKey": invalidValue],
                format: .xml,
                options: 0
            )

            #expect(
                try ReleaseDryRunChecker.productionGate(appPropertyList: data)
                    == .blockedByIssue27MissingSparklePublicKey
            )
        }
    }

    @Test func artifactAndAppcastLengthMismatchFailsClosed() {
        #expect(throws: ReleasePipelineContractError.invalidAppcastMetadata) {
            try ReleaseDryRunChecker.validate(
                ReleaseDryRunInput(
                    appPropertyList: Self.appPropertyList(),
                    appcastXML: Self.appcastXML,
                    artifactByteLength: 43,
                    inspection: Self.inspection
                )
            )
        }
    }

    private static let inspection = ReleaseDryRunInspection(
        fixtureLabel: "synthetic-public-beta",
        currentStableBuild: 1,
        architecture: "arm64",
        sparklePublicKeyConfigured: true,
        artifactFilename: "AgentMetrics-0.1.1.dmg",
        isSigned: true,
        isNotarized: true,
        isStapled: true,
        releaseTag: "v0.1.1",
        draftCreated: true,
        publicArtifactURL: URL(string: "https://downloads.example.invalid/AgentMetrics-0.1.1.dmg")!,
        uploadedArtifactVerified: true,
        releasePublished: true,
        publishedArtifactDownloadVerified: true,
        updaterSignatureAccepted: true,
        updaterUserApprovedInstallation: true
    )

    private static let appcastXML = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://downloads.example.invalid/AgentMetrics-0.1.1.dmg" length="42" sparkle:edSignature="synthetic-signature" />
    </item></channel></rss>
    """

    private static func appPropertyList() -> Data {
        let values: [String: Any] = [
            "CFBundleIdentifier": "dev.codingagentmetrics.app",
            "CFBundleShortVersionString": "0.1.1",
            "CFBundleVersion": "2",
            "LSMinimumSystemVersion": "14.0",
            "SUFeedURL": "https://updates.example.invalid/stable/appcast.xml",
            "SUEnableAutomaticChecks": true,
            "SUAutomaticallyUpdate": false,
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
    }
}

import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

struct ReleaseDryRunCheckerTests {
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

        #expect(gate == .blockedByIssue27MissingSparklePublicKey)
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
        artifactFilename: "CodingAgentMetrics-0.1.1.dmg",
        isSigned: true,
        isNotarized: true,
        isStapled: true,
        releaseTag: "v0.1.1",
        draftCreated: true,
        publicArtifactURL: URL(string: "https://downloads.example.invalid/CodingAgentMetrics-0.1.1.dmg")!,
        uploadedArtifactVerified: true,
        releasePublished: true,
        publishedArtifactDownloadVerified: true,
        updaterSignatureAccepted: true,
        updaterUserApprovedInstallation: true
    )

    private static let appcastXML = """
    <rss xmlns:sparkle="https://sparkle.example.invalid/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://downloads.example.invalid/CodingAgentMetrics-0.1.1.dmg" length="42" sparkle:edSignature="synthetic-signature" />
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

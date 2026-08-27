import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

struct ReleasePipelineContractTests {
    @Test func stableFeedCannotBeAdvertisedBeforeThePublicDMGIsVerified() throws {
        var pipeline = ReleasePipelineContract(currentStableBuild: 1)

        #expect(throws: ReleasePipelineContractError.unexpectedStage(
            expected: .validateApp,
            attempted: .publishStableAppcast
        )) {
            try pipeline.complete(
                .publishStableAppcast,
                evidence: .appcast(Self.validAppcast)
            )
        }
        #expect(pipeline.state == .ready)
    }

    @Test func syntheticEvidenceAdvancesOnlyThroughTheDocumentedOrder() throws {
        var pipeline = ReleasePipelineContract(currentStableBuild: 1)

        try pipeline.complete(.validateApp, evidence: .app(Self.app))
        #expect(pipeline.state == .appValidated)
        try pipeline.complete(.signNotarizeAndStapleDMG, evidence: .dmg(Self.dmg))
        #expect(pipeline.state == .dmgSignedNotarizedAndStapled)
        try pipeline.complete(.createDraftRelease, evidence: .draft(Self.draft))
        #expect(pipeline.state == .draftReleaseCreated)
        try pipeline.complete(.uploadAndVerifyPublicDMG, evidence: .publicArtifact(Self.publicArtifact))
        #expect(pipeline.state == .publicDMGVerified)
        try pipeline.complete(.publishRelease, evidence: .release(Self.publication))
        #expect(pipeline.state == .releasePublished)
        try pipeline.complete(.publishStableAppcast, evidence: .appcast(Self.validAppcast))
        #expect(pipeline.state == .stableAppcastPublished)
        try pipeline.complete(.verifyUpdater, evidence: .updater(Self.updater))
        #expect(pipeline.state == .updaterVerified)
    }

    @Test func stableFeedValidatesNewestReleaseAndPreservesDescendingHistory() throws {
        var pipeline = try Self.pipelineThroughPublishedRelease()
        let feed = Self.appcastFeedXML([
            Self.itemXML(version: "2", shortVersion: "0.1.1"),
            Self.itemXML(version: "1", shortVersion: "0.1.0"),
        ])

        try pipeline.complete(.publishStableAppcast, evidence: .appcast(feed))
        #expect(pipeline.state == .stableAppcastPublished)
    }

    @Test func stableFeedRejectsLatestSignatureThatDiffersFromVerifiedArtifact() throws {
        var pipeline = try Self.pipelineThroughPublicDMGWithSignature("verified-signature")
        let feed = Self.appcastFeedXML([
            Self.itemXML(version: "2", shortVersion: "0.1.1", edSignature: "different-signature"),
            Self.itemXML(version: "1", shortVersion: "0.1.0"),
        ])

        #expect(throws: ReleasePipelineContractError.invalidAppcastMetadata) {
            try pipeline.complete(.publishStableAppcast, evidence: .appcast(feed))
        }
    }

    @Test func stableBuildRollbackFailsClosed() {
        var pipeline = ReleasePipelineContract(currentStableBuild: 2)

        #expect(throws: ReleasePipelineContractError.buildNotMonotonic) {
            try pipeline.complete(.validateApp, evidence: .app(Self.app))
        }
        #expect(pipeline.state == .ready)
    }

    @Test func aCompletedStageCannotBeRepeated() throws {
        var pipeline = ReleasePipelineContract(currentStableBuild: 1)
        try pipeline.complete(.validateApp, evidence: .app(Self.app))

        #expect(throws: ReleasePipelineContractError.repeatedStage(.validateApp)) {
            try pipeline.complete(.validateApp, evidence: .app(Self.app))
        }
        #expect(pipeline.state == .appValidated)
        #expect(pipeline.completedStages == [.validateApp])
    }

    @Test(arguments: [
        ReleaseAppEvidence(identity: identity, architecture: "x86_64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: true, automaticChecksEnabled: true, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: ReleaseIdentity(bundleIdentifier: "invalid.bundle", shortVersion: "0.1.1", build: 2, minimumSystemVersion: "14.0"), architecture: "arm64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: true, automaticChecksEnabled: true, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "release", build: 2, minimumSystemVersion: "14.0"), architecture: "arm64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: true, automaticChecksEnabled: true, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "0.1.1", build: 2, minimumSystemVersion: "13.0"), architecture: "arm64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: true, automaticChecksEnabled: true, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: identity, architecture: "arm64", stableFeedURL: URL(string: "http://updates.example.invalid/appcast.xml")!, hasSparklePublicKey: true, automaticChecksEnabled: true, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: identity, architecture: "arm64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: false, automaticChecksEnabled: true, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: identity, architecture: "arm64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: true, automaticChecksEnabled: false, automaticInstallationEnabled: false),
        ReleaseAppEvidence(identity: identity, architecture: "arm64", stableFeedURL: app.stableFeedURL, hasSparklePublicKey: true, automaticChecksEnabled: true, automaticInstallationEnabled: true),
    ])
    func invalidAppEvidenceFailsClosed(value: ReleaseAppEvidence) {
        var pipeline = ReleasePipelineContract(currentStableBuild: 1)

        #expect(throws: ReleasePipelineContractError.invalidApp) {
            try pipeline.complete(.validateApp, evidence: .app(value))
        }
        #expect(pipeline.state == .ready)
    }

    @Test(arguments: [
        ReleaseDMGEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "0.1.2", build: 2, minimumSystemVersion: "14.0"), filename: dmg.filename, byteLength: 42, isSigned: true, isNotarized: true, isStapled: true),
        ReleaseDMGEvidence(identity: identity, filename: "wrong-name.dmg", byteLength: 42, isSigned: true, isNotarized: true, isStapled: true),
        ReleaseDMGEvidence(identity: identity, filename: dmg.filename, byteLength: 0, isSigned: true, isNotarized: true, isStapled: true),
        ReleaseDMGEvidence(identity: identity, filename: dmg.filename, byteLength: 42, isSigned: false, isNotarized: true, isStapled: true),
        ReleaseDMGEvidence(identity: identity, filename: dmg.filename, byteLength: 42, isSigned: true, isNotarized: false, isStapled: true),
        ReleaseDMGEvidence(identity: identity, filename: dmg.filename, byteLength: 42, isSigned: true, isNotarized: true, isStapled: false),
    ])
    func unsafeDMGCannotAdvanceToDraftCreation(value: ReleaseDMGEvidence) throws {
        var pipeline = ReleasePipelineContract(currentStableBuild: 1)
        try pipeline.complete(.validateApp, evidence: .app(Self.app))

        #expect(throws: ReleasePipelineContractError.invalidDMG) {
            try pipeline.complete(.signNotarizeAndStapleDMG, evidence: .dmg(value))
        }
        #expect(pipeline.state == .appValidated)
    }

    @Test(arguments: [
        ReleaseDraftEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "0.1.2", build: 2, minimumSystemVersion: "14.0"), tag: "v0.1.1", isDraft: true),
        ReleaseDraftEvidence(identity: identity, tag: "v0.1.2", isDraft: true),
        ReleaseDraftEvidence(identity: identity, tag: "v0.1.1", isDraft: false),
    ])
    func onlyTheMatchingDraftCanAdvance(value: ReleaseDraftEvidence) throws {
        var pipeline = try Self.pipelineThroughSecuredDMG()

        #expect(throws: ReleasePipelineContractError.invalidDraftRelease) {
            try pipeline.complete(.createDraftRelease, evidence: .draft(value))
        }
        #expect(pipeline.state == .dmgSignedNotarizedAndStapled)
    }

    @Test(arguments: [
        ReleasePublicArtifactEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "0.1.2", build: 2, minimumSystemVersion: "14.0"), url: publicArtifact.url, filename: publicArtifact.filename, byteLength: 42, uploadVerified: true),
        ReleasePublicArtifactEvidence(identity: identity, url: URL(string: "http://downloads.example.invalid/AgentMetrics-0.1.1.dmg")!, filename: publicArtifact.filename, byteLength: 42, uploadVerified: true),
        ReleasePublicArtifactEvidence(identity: identity, url: URL(string: "https://downloads.example.invalid/wrong-name.dmg")!, filename: publicArtifact.filename, byteLength: 42, uploadVerified: true),
        ReleasePublicArtifactEvidence(identity: identity, url: publicArtifact.url, filename: "wrong-name.dmg", byteLength: 42, uploadVerified: true),
        ReleasePublicArtifactEvidence(identity: identity, url: publicArtifact.url, filename: publicArtifact.filename, byteLength: 43, uploadVerified: true),
        ReleasePublicArtifactEvidence(identity: identity, url: publicArtifact.url, filename: publicArtifact.filename, byteLength: 42, uploadVerified: false),
    ])
    func onlyTheVerifiedPublicDMGCanAdvance(value: ReleasePublicArtifactEvidence) throws {
        var pipeline = try Self.pipelineThroughDraft()

        #expect(throws: ReleasePipelineContractError.invalidPublicArtifact) {
            try pipeline.complete(.uploadAndVerifyPublicDMG, evidence: .publicArtifact(value))
        }
        #expect(pipeline.state == .draftReleaseCreated)
    }

    @Test(arguments: [
        ReleasePublicationEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "0.1.2", build: 2, minimumSystemVersion: "14.0"), tag: "v0.1.1", isPublished: true, publicArtifactURL: publicArtifact.url, publicArtifactByteLength: 42, publicDownloadVerified: true),
        ReleasePublicationEvidence(identity: identity, tag: "v0.1.2", isPublished: true, publicArtifactURL: publicArtifact.url, publicArtifactByteLength: 42, publicDownloadVerified: true),
        ReleasePublicationEvidence(identity: identity, tag: "v0.1.1", isPublished: false, publicArtifactURL: publicArtifact.url, publicArtifactByteLength: 42, publicDownloadVerified: true),
        ReleasePublicationEvidence(identity: identity, tag: "v0.1.1", isPublished: true, publicArtifactURL: URL(string: "https://downloads.example.invalid/wrong-name.dmg")!, publicArtifactByteLength: 42, publicDownloadVerified: true),
        ReleasePublicationEvidence(identity: identity, tag: "v0.1.1", isPublished: true, publicArtifactURL: publicArtifact.url, publicArtifactByteLength: 43, publicDownloadVerified: true),
        ReleasePublicationEvidence(identity: identity, tag: "v0.1.1", isPublished: true, publicArtifactURL: publicArtifact.url, publicArtifactByteLength: 42, publicDownloadVerified: false),
    ])
    func onlyTheMatchingPublishedReleaseCanAdvance(value: ReleasePublicationEvidence) throws {
        var pipeline = try Self.pipelineThroughPublicDMG()

        #expect(throws: ReleasePipelineContractError.invalidPublishedRelease) {
            try pipeline.complete(.publishRelease, evidence: .release(value))
        }
        #expect(pipeline.state == .publicDMGVerified)
    }

    @Test(arguments: [
        validAppcast.replacingOccurrences(of: "<sparkle:version>2", with: "<sparkle:version>3"),
        validAppcast.replacingOccurrences(of: "<sparkle:shortVersionString>0.1.1", with: "<sparkle:shortVersionString>0.1.2"),
        validAppcast.replacingOccurrences(of: "<sparkle:minimumSystemVersion>14.0", with: "<sparkle:minimumSystemVersion>13.0"),
        validAppcast.replacingOccurrences(of: "AgentMetrics-0.1.1.dmg", with: "wrong-name.dmg"),
        validAppcast.replacingOccurrences(of: "length=\"42\"", with: "length=\"43\""),
        validAppcast.replacingOccurrences(of: "<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>\n", with: ""),
        validAppcast.replacingOccurrences(of: "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n", with: ""),
    ])
    func appcastMetadataMustMatchTheVerifiedArtifact(xml: String) throws {
        var pipeline = try Self.pipelineThroughPublishedRelease()

        #expect(throws: ReleasePipelineContractError.invalidAppcastMetadata) {
            try pipeline.complete(.publishStableAppcast, evidence: .appcast(xml))
        }
        #expect(pipeline.state == .releasePublished)
    }

    @Test func unsafeAppcastContractCannotAdvance() throws {
        var pipeline = try Self.pipelineThroughPublishedRelease()
        let beta = Self.validAppcast.replacingOccurrences(
            of: "<sparkle:version>2</sparkle:version>",
            with: "<sparkle:version>2</sparkle:version><sparkle:channel>beta</sparkle:channel>"
        )

        #expect(throws: AppcastReleaseContractError.nonStableChannel) {
            try pipeline.complete(.publishStableAppcast, evidence: .appcast(beta))
        }
        #expect(pipeline.state == .releasePublished)
    }

    @Test(arguments: [
        ReleaseUpdaterEvidence(identity: ReleaseIdentity(bundleIdentifier: identity.bundleIdentifier, shortVersion: "0.1.2", build: 2, minimumSystemVersion: "14.0"), feedURL: updater.feedURL, artifactURL: updater.artifactURL, signatureAccepted: true, userApprovedInstallation: true),
        ReleaseUpdaterEvidence(identity: identity, feedURL: URL(string: "https://other.example.invalid/appcast.xml")!, artifactURL: updater.artifactURL, signatureAccepted: true, userApprovedInstallation: true),
        ReleaseUpdaterEvidence(identity: identity, feedURL: updater.feedURL, artifactURL: URL(string: "https://downloads.example.invalid/wrong-name.dmg")!, signatureAccepted: true, userApprovedInstallation: true),
        ReleaseUpdaterEvidence(identity: identity, feedURL: updater.feedURL, artifactURL: updater.artifactURL, signatureAccepted: false, userApprovedInstallation: true),
        ReleaseUpdaterEvidence(identity: identity, feedURL: updater.feedURL, artifactURL: updater.artifactURL, signatureAccepted: true, userApprovedInstallation: false),
    ])
    func updaterMustVerifyTheExactPublishedRelease(value: ReleaseUpdaterEvidence) throws {
        var pipeline = try Self.pipelineThroughStableAppcast()

        #expect(throws: ReleasePipelineContractError.invalidUpdaterVerification) {
            try pipeline.complete(.verifyUpdater, evidence: .updater(value))
        }
        #expect(pipeline.state == .stableAppcastPublished)
    }

    private static let identity = ReleaseIdentity(
        bundleIdentifier: "dev.codingagentmetrics.app",
        shortVersion: "0.1.1",
        build: 2,
        minimumSystemVersion: "14.0"
    )
    private static let app = ReleaseAppEvidence(
        identity: identity,
        architecture: "arm64",
        stableFeedURL: URL(string: "https://updates.example.invalid/stable/appcast.xml")!,
        hasSparklePublicKey: true,
        automaticChecksEnabled: true,
        automaticInstallationEnabled: false
    )
    private static let dmg = ReleaseDMGEvidence(
        identity: identity,
        filename: "AgentMetrics-0.1.1.dmg",
        byteLength: 42,
        isSigned: true,
        isNotarized: true,
        isStapled: true
    )
    private static let draft = ReleaseDraftEvidence(
        identity: identity,
        tag: "v0.1.1",
        isDraft: true
    )
    private static let publicArtifact = ReleasePublicArtifactEvidence(
        identity: identity,
        url: URL(string: "https://downloads.example.invalid/AgentMetrics-0.1.1.dmg")!,
        filename: "AgentMetrics-0.1.1.dmg",
        byteLength: 42,
        uploadVerified: true
    )
    private static let publication = ReleasePublicationEvidence(
        identity: identity,
        tag: "v0.1.1",
        isPublished: true,
        publicArtifactURL: publicArtifact.url,
        publicArtifactByteLength: 42,
        publicDownloadVerified: true
    )
    private static let updater = ReleaseUpdaterEvidence(
        identity: identity,
        feedURL: URL(string: "https://updates.example.invalid/stable/appcast.xml")!,
        artifactURL: URL(string: "https://downloads.example.invalid/AgentMetrics-0.1.1.dmg")!,
        signatureAccepted: true,
        userApprovedInstallation: true
    )

    private static func pipelineThroughSecuredDMG() throws -> ReleasePipelineContract {
        var pipeline = ReleasePipelineContract(currentStableBuild: 1)
        try pipeline.complete(.validateApp, evidence: .app(app))
        try pipeline.complete(.signNotarizeAndStapleDMG, evidence: .dmg(dmg))
        return pipeline
    }

    private static func pipelineThroughDraft() throws -> ReleasePipelineContract {
        var pipeline = try pipelineThroughSecuredDMG()
        try pipeline.complete(.createDraftRelease, evidence: .draft(draft))
        return pipeline
    }

    private static func pipelineThroughPublicDMG() throws -> ReleasePipelineContract {
        var pipeline = try pipelineThroughDraft()
        try pipeline.complete(.uploadAndVerifyPublicDMG, evidence: .publicArtifact(publicArtifact))
        return pipeline
    }

    private static func pipelineThroughPublishedRelease() throws -> ReleasePipelineContract {
        var pipeline = try pipelineThroughPublicDMG()
        try pipeline.complete(.publishRelease, evidence: .release(publication))
        return pipeline
    }

    private static func pipelineThroughPublicDMGWithSignature(_ signature: String) throws -> ReleasePipelineContract {
        var pipeline = try pipelineThroughDraft()
        let artifact = ReleasePublicArtifactEvidence(
            identity: identity,
            url: publicArtifact.url,
            filename: publicArtifact.filename,
            byteLength: publicArtifact.byteLength,
            edDSASignature: signature,
            uploadVerified: true
        )
        try pipeline.complete(.uploadAndVerifyPublicDMG, evidence: .publicArtifact(artifact))
        try pipeline.complete(.publishRelease, evidence: .release(publication))
        return pipeline
    }

    private static func pipelineThroughStableAppcast() throws -> ReleasePipelineContract {
        var pipeline = try pipelineThroughPublishedRelease()
        try pipeline.complete(.publishStableAppcast, evidence: .appcast(validAppcast))
        return pipeline
    }

    private static let validAppcast = """
    <rss xmlns:sparkle="https://sparkle.example.invalid/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://downloads.example.invalid/AgentMetrics-0.1.1.dmg" length="42" sparkle:edSignature="synthetic-signature" />
    </item></channel></rss>
    """

    private static func appcastFeedXML(_ items: [String]) -> String {
        "<rss xmlns:sparkle=\"https://sparkle.example.invalid/xml-namespaces/sparkle\"><channel>\(items.joined())</channel></rss>"
    }

    private static func itemXML(
        version: String,
        shortVersion: String,
        edSignature: String = "synthetic-signature"
    ) -> String {
        """
        <item><sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url=\"https://downloads.example.invalid/AgentMetrics-\(shortVersion).dmg\" length=\"42\" sparkle:edSignature=\"\(edSignature)\" /></item>
        """
    }
}

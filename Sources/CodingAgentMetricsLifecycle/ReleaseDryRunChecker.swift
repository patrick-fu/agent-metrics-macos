import Foundation

public struct ReleaseDryRunInspection: Codable, Equatable, Sendable {
    public let fixtureLabel: String
    public let currentStableBuild: Int
    public let architecture: String
    public let sparklePublicKeyConfigured: Bool
    public let artifactFilename: String
    public let isSigned: Bool
    public let isNotarized: Bool
    public let isStapled: Bool
    public let releaseTag: String
    public let draftCreated: Bool
    public let publicArtifactURL: URL
    public let uploadedArtifactVerified: Bool
    public let releasePublished: Bool
    public let publishedArtifactDownloadVerified: Bool
    public let updaterSignatureAccepted: Bool
    public let updaterUserApprovedInstallation: Bool

    public init(
        fixtureLabel: String,
        currentStableBuild: Int,
        architecture: String,
        sparklePublicKeyConfigured: Bool,
        artifactFilename: String,
        isSigned: Bool,
        isNotarized: Bool,
        isStapled: Bool,
        releaseTag: String,
        draftCreated: Bool,
        publicArtifactURL: URL,
        uploadedArtifactVerified: Bool,
        releasePublished: Bool,
        publishedArtifactDownloadVerified: Bool,
        updaterSignatureAccepted: Bool,
        updaterUserApprovedInstallation: Bool
    ) {
        self.fixtureLabel = fixtureLabel
        self.currentStableBuild = currentStableBuild
        self.architecture = architecture
        self.sparklePublicKeyConfigured = sparklePublicKeyConfigured
        self.artifactFilename = artifactFilename
        self.isSigned = isSigned
        self.isNotarized = isNotarized
        self.isStapled = isStapled
        self.releaseTag = releaseTag
        self.draftCreated = draftCreated
        self.publicArtifactURL = publicArtifactURL
        self.uploadedArtifactVerified = uploadedArtifactVerified
        self.releasePublished = releasePublished
        self.publishedArtifactDownloadVerified = publishedArtifactDownloadVerified
        self.updaterSignatureAccepted = updaterSignatureAccepted
        self.updaterUserApprovedInstallation = updaterUserApprovedInstallation
    }
}

public struct ReleaseDryRunInput: Equatable, Sendable {
    public let appPropertyList: Data
    public let appcastXML: String
    public let artifactByteLength: UInt64
    public let inspection: ReleaseDryRunInspection

    public init(
        appPropertyList: Data,
        appcastXML: String,
        artifactByteLength: UInt64,
        inspection: ReleaseDryRunInspection
    ) {
        self.appPropertyList = appPropertyList
        self.appcastXML = appcastXML
        self.artifactByteLength = artifactByteLength
        self.inspection = inspection
    }
}

public enum ReleaseCheckMode: Equatable, Sendable {
    case syntheticDryRun
}

public struct ReleaseDryRunSummary: Equatable, Sendable {
    public let mode: ReleaseCheckMode
    public let fixtureLabel: String
    public let finalState: ReleasePipelineState
    public let completedStages: [ReleasePipelineStage]
}

public enum ProductionReleaseGate: Equatable, Sendable {
    case blockedByIssue27MissingSparklePublicKey
    case requiresIssue27ManualKeyValidation
}

public enum ReleaseDryRunCheckerError: Error, Equatable, Sendable {
    case invalidAppPropertyList
    case invalidFixtureLabel
}

/// Validates only supplied synthetic/local evidence. It has no network or command execution seam.
public enum ReleaseDryRunChecker {
    public static func validate(_ input: ReleaseDryRunInput) throws -> ReleaseDryRunSummary {
        let plist = try parsePropertyList(input.appPropertyList)
        guard input.inspection.fixtureLabel.range(
            of: #"^[a-z0-9][a-z0-9-]{0,63}$"#,
            options: .regularExpression
        ) != nil else {
            throw ReleaseDryRunCheckerError.invalidFixtureLabel
        }
        let app = try appEvidence(
            from: plist,
            architecture: input.inspection.architecture,
            sparklePublicKeyConfigured: input.inspection.sparklePublicKeyConfigured
        )
        let identity = app.identity
        let inspection = input.inspection
        let dmg = ReleaseDMGEvidence(
            identity: identity,
            filename: inspection.artifactFilename,
            byteLength: input.artifactByteLength,
            isSigned: inspection.isSigned,
            isNotarized: inspection.isNotarized,
            isStapled: inspection.isStapled
        )
        let draft = ReleaseDraftEvidence(
            identity: identity,
            tag: inspection.releaseTag,
            isDraft: inspection.draftCreated
        )
        let publicArtifact = ReleasePublicArtifactEvidence(
            identity: identity,
            url: inspection.publicArtifactURL,
            filename: inspection.artifactFilename,
            byteLength: input.artifactByteLength,
            uploadVerified: inspection.uploadedArtifactVerified
        )
        let publication = ReleasePublicationEvidence(
            identity: identity,
            tag: inspection.releaseTag,
            isPublished: inspection.releasePublished,
            publicArtifactURL: inspection.publicArtifactURL,
            publicArtifactByteLength: input.artifactByteLength,
            publicDownloadVerified: inspection.publishedArtifactDownloadVerified
        )
        let updater = ReleaseUpdaterEvidence(
            identity: identity,
            feedURL: app.stableFeedURL,
            artifactURL: inspection.publicArtifactURL,
            signatureAccepted: inspection.updaterSignatureAccepted,
            userApprovedInstallation: inspection.updaterUserApprovedInstallation
        )

        var pipeline = ReleasePipelineContract(currentStableBuild: inspection.currentStableBuild)
        try pipeline.complete(.validateApp, evidence: .app(app))
        try pipeline.complete(.signNotarizeAndStapleDMG, evidence: .dmg(dmg))
        try pipeline.complete(.createDraftRelease, evidence: .draft(draft))
        try pipeline.complete(.uploadAndVerifyPublicDMG, evidence: .publicArtifact(publicArtifact))
        try pipeline.complete(.publishRelease, evidence: .release(publication))
        try pipeline.complete(.publishStableAppcast, evidence: .appcast(input.appcastXML))
        try pipeline.complete(.verifyUpdater, evidence: .updater(updater))

        return ReleaseDryRunSummary(
            mode: .syntheticDryRun,
            fixtureLabel: inspection.fixtureLabel,
            finalState: pipeline.state,
            completedStages: pipeline.completedStages
        )
    }

    public static func productionGate(appPropertyList: Data) throws -> ProductionReleaseGate {
        let plist = try parsePropertyList(appPropertyList)
        guard let publicKey = plist["SUPublicEDKey"] as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .blockedByIssue27MissingSparklePublicKey
        }
        return .requiresIssue27ManualKeyValidation
    }

    private static func parsePropertyList(_ data: Data) throws -> [String: Any] {
        guard let values = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any] else {
            throw ReleaseDryRunCheckerError.invalidAppPropertyList
        }
        return values
    }

    private static func appEvidence(
        from values: [String: Any],
        architecture: String,
        sparklePublicKeyConfigured: Bool
    ) throws -> ReleaseAppEvidence {
        guard let bundleIdentifier = values["CFBundleIdentifier"] as? String,
              let shortVersion = values["CFBundleShortVersionString"] as? String,
              let buildText = values["CFBundleVersion"] as? String,
              let build = Int(buildText),
              let minimumSystemVersion = values["LSMinimumSystemVersion"] as? String,
              let feedText = values["SUFeedURL"] as? String,
              let feedURL = URL(string: feedText),
              let automaticChecks = values["SUEnableAutomaticChecks"] as? Bool,
              let automaticInstallation = values["SUAutomaticallyUpdate"] as? Bool else {
            throw ReleaseDryRunCheckerError.invalidAppPropertyList
        }
        return ReleaseAppEvidence(
            identity: ReleaseIdentity(
                bundleIdentifier: bundleIdentifier,
                shortVersion: shortVersion,
                build: build,
                minimumSystemVersion: minimumSystemVersion
            ),
            architecture: architecture,
            stableFeedURL: feedURL,
            hasSparklePublicKey: sparklePublicKeyConfigured,
            automaticChecksEnabled: automaticChecks,
            automaticInstallationEnabled: automaticInstallation
        )
    }
}

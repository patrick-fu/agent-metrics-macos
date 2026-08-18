import Foundation

public struct ReleaseIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let shortVersion: String
    public let build: Int
    public let minimumSystemVersion: String

    public init(
        bundleIdentifier: String,
        shortVersion: String,
        build: Int,
        minimumSystemVersion: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public struct ReleaseAppEvidence: Equatable, Sendable {
    public let identity: ReleaseIdentity
    public let architecture: String
    public let stableFeedURL: URL
    public let hasSparklePublicKey: Bool
    public let automaticChecksEnabled: Bool
    public let automaticInstallationEnabled: Bool

    public init(
        identity: ReleaseIdentity,
        architecture: String,
        stableFeedURL: URL,
        hasSparklePublicKey: Bool,
        automaticChecksEnabled: Bool,
        automaticInstallationEnabled: Bool
    ) {
        self.identity = identity
        self.architecture = architecture
        self.stableFeedURL = stableFeedURL
        self.hasSparklePublicKey = hasSparklePublicKey
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticInstallationEnabled = automaticInstallationEnabled
    }
}

public struct ReleaseDMGEvidence: Equatable, Sendable {
    public let identity: ReleaseIdentity
    public let filename: String
    public let byteLength: UInt64
    public let isSigned: Bool
    public let isNotarized: Bool
    public let isStapled: Bool

    public init(
        identity: ReleaseIdentity,
        filename: String,
        byteLength: UInt64,
        isSigned: Bool,
        isNotarized: Bool,
        isStapled: Bool
    ) {
        self.identity = identity
        self.filename = filename
        self.byteLength = byteLength
        self.isSigned = isSigned
        self.isNotarized = isNotarized
        self.isStapled = isStapled
    }
}

public struct ReleaseDraftEvidence: Equatable, Sendable {
    public let identity: ReleaseIdentity
    public let tag: String
    public let isDraft: Bool

    public init(identity: ReleaseIdentity, tag: String, isDraft: Bool) {
        self.identity = identity
        self.tag = tag
        self.isDraft = isDraft
    }
}

public struct ReleasePublicArtifactEvidence: Equatable, Sendable {
    public let identity: ReleaseIdentity
    public let url: URL
    public let filename: String
    public let byteLength: UInt64
    public let uploadVerified: Bool

    public init(
        identity: ReleaseIdentity,
        url: URL,
        filename: String,
        byteLength: UInt64,
        uploadVerified: Bool
    ) {
        self.identity = identity
        self.url = url
        self.filename = filename
        self.byteLength = byteLength
        self.uploadVerified = uploadVerified
    }
}

public struct ReleasePublicationEvidence: Equatable, Sendable {
    public let identity: ReleaseIdentity
    public let tag: String
    public let isPublished: Bool
    public let publicArtifactURL: URL
    public let publicArtifactByteLength: UInt64
    public let publicDownloadVerified: Bool

    public init(
        identity: ReleaseIdentity,
        tag: String,
        isPublished: Bool,
        publicArtifactURL: URL,
        publicArtifactByteLength: UInt64,
        publicDownloadVerified: Bool
    ) {
        self.identity = identity
        self.tag = tag
        self.isPublished = isPublished
        self.publicArtifactURL = publicArtifactURL
        self.publicArtifactByteLength = publicArtifactByteLength
        self.publicDownloadVerified = publicDownloadVerified
    }
}

public struct ReleaseUpdaterEvidence: Equatable, Sendable {
    public let identity: ReleaseIdentity
    public let feedURL: URL
    public let artifactURL: URL
    public let signatureAccepted: Bool
    public let userApprovedInstallation: Bool

    public init(
        identity: ReleaseIdentity,
        feedURL: URL,
        artifactURL: URL,
        signatureAccepted: Bool,
        userApprovedInstallation: Bool
    ) {
        self.identity = identity
        self.feedURL = feedURL
        self.artifactURL = artifactURL
        self.signatureAccepted = signatureAccepted
        self.userApprovedInstallation = userApprovedInstallation
    }
}

public enum ReleasePipelineStage: String, CaseIterable, Equatable, Sendable {
    case validateApp
    case signNotarizeAndStapleDMG
    case createDraftRelease
    case uploadAndVerifyPublicDMG
    case publishRelease
    case publishStableAppcast
    case verifyUpdater
}

public enum ReleasePipelineState: Equatable, Sendable {
    case ready
    case appValidated
    case dmgSignedNotarizedAndStapled
    case draftReleaseCreated
    case publicDMGVerified
    case releasePublished
    case stableAppcastPublished
    case updaterVerified

    fileprivate var nextStage: ReleasePipelineStage? {
        switch self {
        case .ready: .validateApp
        case .appValidated: .signNotarizeAndStapleDMG
        case .dmgSignedNotarizedAndStapled: .createDraftRelease
        case .draftReleaseCreated: .uploadAndVerifyPublicDMG
        case .publicDMGVerified: .publishRelease
        case .releasePublished: .publishStableAppcast
        case .stableAppcastPublished: .verifyUpdater
        case .updaterVerified: nil
        }
    }
}

public enum ReleasePipelineEvidence: Equatable, Sendable {
    case app(ReleaseAppEvidence)
    case dmg(ReleaseDMGEvidence)
    case draft(ReleaseDraftEvidence)
    case publicArtifact(ReleasePublicArtifactEvidence)
    case release(ReleasePublicationEvidence)
    case appcast(String)
    case updater(ReleaseUpdaterEvidence)
}

public enum ReleasePipelineContractError: Error, Equatable, Sendable {
    case unexpectedStage(expected: ReleasePipelineStage, attempted: ReleasePipelineStage)
    case repeatedStage(ReleasePipelineStage)
    case pipelineAlreadyCompleted
    case evidenceDoesNotMatchStage
    case buildNotMonotonic
    case invalidApp
    case invalidDMG
    case invalidDraftRelease
    case invalidPublicArtifact
    case invalidPublishedRelease
    case invalidAppcastMetadata
    case invalidUpdaterVerification
}

/// A pure local release contract. It records supplied evidence only; it cannot sign, publish,
/// access the network, or use credentials. Real stages require separate, explicit human action.
public struct ReleasePipelineContract: Equatable, Sendable {
    public private(set) var state: ReleasePipelineState = .ready
    public private(set) var completedStages: [ReleasePipelineStage] = []
    private let currentStableBuild: Int
    private var app: ReleaseAppEvidence?
    private var dmg: ReleaseDMGEvidence?
    private var publicArtifact: ReleasePublicArtifactEvidence?

    public init(currentStableBuild: Int) {
        self.currentStableBuild = currentStableBuild
    }

    public mutating func complete(
        _ stage: ReleasePipelineStage,
        evidence: ReleasePipelineEvidence
    ) throws {
        guard !completedStages.contains(stage) else {
            throw ReleasePipelineContractError.repeatedStage(stage)
        }
        guard let expected = state.nextStage else {
            throw ReleasePipelineContractError.pipelineAlreadyCompleted
        }
        guard stage == expected else {
            throw ReleasePipelineContractError.unexpectedStage(expected: expected, attempted: stage)
        }

        switch (stage, evidence) {
        case let (.validateApp, .app(value)):
            guard value.identity.build > currentStableBuild else {
                throw ReleasePipelineContractError.buildNotMonotonic
            }
            guard Self.isValidApp(value) else {
                throw ReleasePipelineContractError.invalidApp
            }
            app = value
            state = .appValidated
        case let (.signNotarizeAndStapleDMG, .dmg(value)):
            guard let app,
                  value.identity == app.identity,
                  value.filename == "CodingAgentMetrics-\(app.identity.shortVersion).dmg",
                  value.byteLength > 0,
                  value.isSigned,
                  value.isNotarized,
                  value.isStapled else {
                throw ReleasePipelineContractError.invalidDMG
            }
            dmg = value
            state = .dmgSignedNotarizedAndStapled
        case let (.createDraftRelease, .draft(value)):
            guard let app,
                  value.identity == app.identity,
                  value.tag == "v\(app.identity.shortVersion)",
                  value.isDraft else {
                throw ReleasePipelineContractError.invalidDraftRelease
            }
            state = .draftReleaseCreated
        case let (.uploadAndVerifyPublicDMG, .publicArtifact(value)):
            guard let dmg,
                  value.identity == dmg.identity,
                  value.url.scheme?.lowercased() == "https",
                  value.url.host != nil,
                  value.url.user == nil,
                  value.url.password == nil,
                  value.url.query == nil,
                  value.url.fragment == nil,
                  value.url.lastPathComponent == value.filename,
                  value.filename == dmg.filename,
                  value.byteLength == dmg.byteLength,
                  value.uploadVerified else {
                throw ReleasePipelineContractError.invalidPublicArtifact
            }
            publicArtifact = value
            state = .publicDMGVerified
        case let (.publishRelease, .release(value)):
            guard let app,
                  let publicArtifact,
                  value.identity == app.identity,
                  value.tag == "v\(app.identity.shortVersion)",
                  value.isPublished,
                  value.publicArtifactURL == publicArtifact.url,
                  value.publicArtifactByteLength == publicArtifact.byteLength,
                  value.publicDownloadVerified else {
                throw ReleasePipelineContractError.invalidPublishedRelease
            }
            state = .releasePublished
        case let (.publishStableAppcast, .appcast(xml)):
            let release = try AppcastReleaseContract.validate(xml, currentBuild: currentStableBuild)
            guard let app,
                  let publicArtifact,
                  release.version == app.identity.build,
                  release.shortVersion == app.identity.shortVersion,
                  release.minimumSystemVersion == app.identity.minimumSystemVersion,
                  release.archiveURL == publicArtifact.url,
                  release.archiveURL.lastPathComponent == publicArtifact.filename,
                  release.archiveLength == publicArtifact.byteLength else {
                throw ReleasePipelineContractError.invalidAppcastMetadata
            }
            state = .stableAppcastPublished
        case let (.verifyUpdater, .updater(value)):
            guard let app,
                  let publicArtifact,
                  value.identity == app.identity,
                  value.feedURL == app.stableFeedURL,
                  value.artifactURL == publicArtifact.url,
                  value.signatureAccepted,
                  value.userApprovedInstallation else {
                throw ReleasePipelineContractError.invalidUpdaterVerification
            }
            state = .updaterVerified
        default:
            throw ReleasePipelineContractError.evidenceDoesNotMatchStage
        }
        completedStages.append(stage)
    }

    private static func isValidApp(_ value: ReleaseAppEvidence) -> Bool {
        let versionRange = value.identity.shortVersion.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#,
            options: .regularExpression
        )
        return value.architecture == "arm64"
            && value.identity.bundleIdentifier == "dev.codingagentmetrics.app"
            && versionRange != nil
            && value.identity.build > 0
            && value.identity.minimumSystemVersion == "14.0"
            && value.stableFeedURL.scheme?.lowercased() == "https"
            && value.stableFeedURL.host != nil
            && value.stableFeedURL.user == nil
            && value.stableFeedURL.password == nil
            && value.stableFeedURL.query == nil
            && value.stableFeedURL.fragment == nil
            && value.stableFeedURL.lastPathComponent == "appcast.xml"
            && value.hasSparklePublicKey
            && value.automaticChecksEnabled
            && !value.automaticInstallationEnabled
    }
}

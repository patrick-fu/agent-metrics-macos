import Foundation

public struct SourceFileCursor: Sendable, Equatable, Codable {
    public var fileIdentity: String
    public var locator: String
    public var generation: String
    public var prefixFingerprint: String
    public var offset: Int64
    public var parserVersion: String

    public init(
        fileIdentity: String,
        locator: String,
        generation: String,
        prefixFingerprint: String,
        offset: Int64,
        parserVersion: String
    ) {
        self.fileIdentity = fileIdentity
        self.locator = locator
        self.generation = generation
        self.prefixFingerprint = prefixFingerprint
        self.offset = offset
        self.parserVersion = parserVersion
    }
}

public enum SourceFactScope: Sendable, Equatable {
    case schemaVersion(String)
    case idPrefix(String)
}

public struct SourceState: Sendable, Equatable, Codable {
    public var sourceID: String
    public var parserVersion: String
    public var files: [String: SourceFileCursor]
    public var watermarks: [String: Int]

    public init(
        sourceID: String,
        parserVersion: String,
        files: [String: SourceFileCursor] = [:],
        watermarks: [String: Int] = [:]
    ) {
        self.sourceID = sourceID
        self.parserVersion = parserVersion
        self.files = files
        self.watermarks = watermarks
    }
}

public struct SourceDiagnostic: Sendable, Equatable {
    public var code: String
    public var sourceID: String

    public init(code: String, sourceID: String) {
        self.code = code
        self.sourceID = sourceID
    }
}

public struct SourceHealth: Sendable, Equatable {
    public var sourceID: String
    public var isHealthy: Bool
    public var diagnosticCode: String?

    public init(sourceID: String, isHealthy: Bool, diagnosticCode: String? = nil) {
        self.sourceID = sourceID
        self.isHealthy = isHealthy
        self.diagnosticCode = diagnosticCode
    }
}

public struct SourceScan: Sendable, Equatable {
    public var observations: [UsageObservation]
    public var state: SourceState
    public var rebuildSource: Bool
    public var rebuiltFileIdentities: [String]
    public var diagnostics: [SourceDiagnostic]
    public var health: SourceHealth

    public init(
        observations: [UsageObservation],
        state: SourceState,
        rebuildSource: Bool,
        rebuiltFileIdentities: [String] = [],
        diagnostics: [SourceDiagnostic] = [],
        health: SourceHealth
    ) {
        self.observations = observations
        self.state = state
        self.rebuildSource = rebuildSource
        self.rebuiltFileIdentities = rebuiltFileIdentities
        self.diagnostics = diagnostics
        self.health = health
    }
}

public protocol IncrementalSourceAdapter: SourceAdapter {
    var sourceID: String { get }
    var sourceRebuildScope: SourceFactScope { get }
    func rebuiltFileScope(for identity: String) -> SourceFactScope
    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan
}

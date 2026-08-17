import Foundation

public struct DiagnosticSourceSummary: Sendable, Equatable {
    public var isHealthy: Bool
    public var reasonCodes: [UnavailableReasonCode]

    public init(isHealthy: Bool, reasonCodes: [UnavailableReasonCode]) {
        self.isHealthy = isHealthy
        self.reasonCodes = reasonCodes
    }
}

public struct DiagnosticMetricSummary: Sendable, Equatable {
    public var quality: MeasurementQuality
    public var coverage: Coverage
    public var ageSeconds: TimeInterval?
    public var reasonCode: UnavailableReasonCode?

    public init(
        quality: MeasurementQuality,
        coverage: Coverage,
        ageSeconds: TimeInterval?,
        reasonCode: UnavailableReasonCode? = nil
    ) {
        self.quality = quality
        self.coverage = coverage
        self.ageSeconds = ageSeconds
        self.reasonCode = reasonCode
    }
}

public struct DiagnosticExportInput: Sendable, Equatable {
    public var appVersion: String
    public var buildVersion: String
    public var parserVersions: [String]
    public var schemaVersions: [String]
    public var sources: [DiagnosticSourceSummary]
    public var metrics: [DiagnosticMetricSummary]

    public init(
        appVersion: String,
        buildVersion: String,
        parserVersions: [String],
        schemaVersions: [String],
        sources: [DiagnosticSourceSummary],
        metrics: [DiagnosticMetricSummary]
    ) {
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.parserVersions = parserVersions
        self.schemaVersions = schemaVersions
        self.sources = sources
        self.metrics = metrics
    }

    public init(
        snapshot: LightSnapshot,
        appVersion: String,
        buildVersion: String,
        parserVersions: [String],
        schemaVersions: [String]
    ) {
        self.init(
            appVersion: appVersion,
            buildVersion: buildVersion,
            parserVersions: parserVersions,
            schemaVersions: schemaVersions,
            sources: snapshot.sourceHealth.map { source in
                DiagnosticSourceSummary(
                    isHealthy: source.isHealthy,
                    reasonCodes: [source.reasonCode].compactMap { $0 }
                )
            },
            metrics: [
                DiagnosticMetricSummary(
                    quality: snapshot.outputThroughput.measurementQuality,
                    coverage: snapshot.outputThroughput.coverage,
                    ageSeconds: snapshot.outputThroughput.freshness.ageSeconds,
                    reasonCode: snapshot.outputThroughput.unavailableReason
                ),
                DiagnosticMetricSummary(
                    quality: snapshot.tokenBurn.measurementQuality,
                    coverage: snapshot.tokenBurn.coverage,
                    ageSeconds: snapshot.tokenBurn.freshness.ageSeconds,
                    reasonCode: snapshot.tokenBurn.unavailableReason
                ),
                DiagnosticMetricSummary(
                    quality: snapshot.calls.measurementQuality,
                    coverage: snapshot.calls.coverage,
                    ageSeconds: snapshot.calls.freshness.ageSeconds,
                    reasonCode: snapshot.calls.unavailableReason
                ),
                Self.metric(snapshot.performance.timeToFirstToken),
                Self.metric(snapshot.performance.endToEnd),
                Self.metric(snapshot.performance.decodeTPS),
            ]
        )
    }

    private static func metric(_ distribution: PerformanceDistribution) -> DiagnosticMetricSummary {
        DiagnosticMetricSummary(
            quality: distribution.measurementQuality,
            coverage: distribution.coverage,
            ageSeconds: distribution.freshness.ageSeconds,
            reasonCode: distribution.unavailableReason
        )
    }
}

public struct DiagnosticExporter: Sendable {
    public static let schema = "coding-agent-metrics-diagnostics-v1"

    public init() {}

    public func preview(_ input: DiagnosticExportInput) throws -> Data {
        let document = Document(input: input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}

private struct Document: Encodable {
    var schema: String
    var versions: Versions
    var sourceHealth: SourceHealthCounts
    var sources: [Source]
    var metricCount: Int
    var qualityCounts: QualityCounts
    var coverageCounts: CoverageCounts
    var relativeAgeCounts: RelativeAgeCounts
    var reasonCounts: [ReasonCount]

    enum CodingKeys: String, CodingKey {
        case schema, versions, sources
        case sourceHealth = "source_health"
        case metricCount = "metric_count"
        case qualityCounts = "quality_counts"
        case coverageCounts = "coverage_counts"
        case relativeAgeCounts = "relative_age_counts"
        case reasonCounts = "reason_counts"
    }

    init(input: DiagnosticExportInput) {
        schema = DiagnosticExporter.schema
        versions = Versions(
            app: VersionAllowlist.semantic(input.appVersion) ?? "unavailable",
            build: VersionAllowlist.build(input.buildVersion) ?? "unavailable",
            parsers: Array(Set(input.parserVersions.compactMap(VersionAllowlist.semantic))).sorted(),
            schemas: Array(Set(input.schemaVersions.filter(VersionAllowlist.schemas.contains))).sorted()
        )
        sourceHealth = SourceHealthCounts(
            healthy: input.sources.count(where: \.isHealthy),
            unhealthy: input.sources.count(where: { !$0.isHealthy })
        )
        let sortedSources = input.sources
            .map { source in
                Source(
                    ordinal: 0,
                    health: source.isHealthy ? "healthy" : "unhealthy",
                    reasonCodes: Array(Set(source.reasonCodes.map(\.rawValue))).sorted()
                )
            }
            .sorted {
                ($0.health, $0.reasonCodes.joined(separator: "\u{0}"))
                    < ($1.health, $1.reasonCodes.joined(separator: "\u{0}"))
            }
        sources = sortedSources.enumerated().map { index, source in
            Source(ordinal: index + 1, health: source.health, reasonCodes: source.reasonCodes)
        }
        metricCount = input.metrics.count
        qualityCounts = QualityCounts(metrics: input.metrics)
        coverageCounts = CoverageCounts(metrics: input.metrics)
        relativeAgeCounts = RelativeAgeCounts(metrics: input.metrics)

        var reasons: [String: Int] = [:]
        for reason in input.sources.flatMap(\.reasonCodes) {
            reasons[reason.rawValue, default: 0] += 1
        }
        for reason in input.metrics.compactMap(\.reasonCode) {
            reasons[reason.rawValue, default: 0] += 1
        }
        reasonCounts = reasons
            .map(ReasonCount.init)
            .sorted { $0.code < $1.code }
    }
}

private enum VersionAllowlist {
    static let schemas: Set<String> = [
        CodexRolloutParser.schemaVersion,
        ClaudeTranscriptParser.schemaVersion,
    ]

    static func build(_ value: String) -> String? {
        guard (1...20).contains(value.count), value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    static func semantic(_ value: String) -> String? {
        guard (1...64).contains(value.count), value.first?.isNumber == true else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.-+")
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              value.contains("."),
              value.split(separator: ".").allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return value
    }
}

private struct Versions: Encodable {
    var app: String
    var build: String
    var parsers: [String]
    var schemas: [String]

    enum CodingKeys: String, CodingKey {
        case app, build, parsers, schemas
    }
}

private struct SourceHealthCounts: Encodable {
    var healthy: Int
    var unhealthy: Int

    enum CodingKeys: String, CodingKey {
        case healthy, unhealthy
    }
}

private struct Source: Encodable {
    var ordinal: Int
    var health: String
    var reasonCodes: [String]

    enum CodingKeys: String, CodingKey {
        case ordinal, health
        case reasonCodes = "reason_codes"
    }
}

private struct QualityCounts: Encodable {
    var measured: Int
    var derived: Int
    var estimated: Int
    var unavailable: Int

    enum CodingKeys: String, CodingKey {
        case measured, derived, estimated, unavailable
    }

    init(metrics: [DiagnosticMetricSummary]) {
        measured = metrics.count(where: { $0.quality == .measured })
        derived = metrics.count(where: { $0.quality == .derived })
        estimated = metrics.count(where: { $0.quality == .estimated })
        unavailable = metrics.count(where: { $0.quality == .unavailable })
    }
}

private struct CoverageCounts: Encodable {
    var complete: Int
    var partial: Int

    enum CodingKeys: String, CodingKey {
        case complete, partial
    }

    init(metrics: [DiagnosticMetricSummary]) {
        complete = metrics.count(where: { $0.coverage == .complete })
        partial = metrics.count(where: { $0.coverage == .partial })
    }
}

private struct RelativeAgeCounts: Encodable {
    var underOneMinute = 0
    var oneToFiveMinutes = 0
    var fiveMinutesToOneHour = 0
    var oneToTwentyFourHours = 0
    var overTwentyFourHours = 0
    var unknown = 0

    enum CodingKeys: String, CodingKey {
        case underOneMinute = "under_1m"
        case oneToFiveMinutes = "1m_to_5m"
        case fiveMinutesToOneHour = "5m_to_1h"
        case oneToTwentyFourHours = "1h_to_24h"
        case overTwentyFourHours = "over_24h"
        case unknown
    }

    init(metrics: [DiagnosticMetricSummary]) {
        for metric in metrics {
            guard let age = metric.ageSeconds, age.isFinite, age >= 0 else {
                unknown += 1
                continue
            }
            switch age {
            case ..<60: underOneMinute += 1
            case ..<300: oneToFiveMinutes += 1
            case ..<3_600: fiveMinutesToOneHour += 1
            case ..<86_400: oneToTwentyFourHours += 1
            default: overTwentyFourHours += 1
            }
        }
    }
}

private struct ReasonCount: Encodable {
    var code: String
    var count: Int

    enum CodingKeys: String, CodingKey {
        case code, count
    }

    init(_ entry: (key: String, value: Int)) {
        code = entry.key
        count = entry.value
    }
}

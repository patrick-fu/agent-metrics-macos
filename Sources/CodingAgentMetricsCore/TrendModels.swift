import Foundation

public enum TrendSeriesRole: Sendable, Equatable {
    case model
    case other
}

/// A chart-only identity cannot collide with a source-reported raw model name.
public enum TrendSeriesIdentity: Sendable, Equatable, Hashable {
    case model(String)
    case aggregate(String)
    case other

    public var accessibilityLabel: String {
        switch self {
        case .model(let raw): raw
        case .aggregate(let name): name
        case .other: "Other models"
        }
    }
}

public enum TrendTokenPart: CaseIterable, Sendable, Equatable, Hashable {
    case inputUncached
    case cacheRead
    case cacheWrite
    case outputVisible
    case reasoning

    public var title: String {
        switch self {
        case .inputUncached: "Input uncached"
        case .cacheRead: "Cache read"
        case .cacheWrite: "Cache write"
        case .outputVisible: "Output visible"
        case .reasoning: "Reasoning"
        }
    }
}

/// Non-color styling cues exposed to the view layer.
public enum TrendSeriesEmphasis: Sendable, Equatable {
    case normal
    case estimated
    case partial
    case other
}

public struct TrendBucket: Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var isComplete: Bool
    /// The chart's normalized y value. Nil means no observation, not zero.
    public var value: Double?
    /// The exact, un-normalized amount for tooltips and accessible tables.
    public var absoluteCount: Int?
    public var parts: TokenParts?

    public var id: Date { start }

    public init(start: Date, end: Date, isComplete: Bool, value: Double?, absoluteCount: Int?, parts: TokenParts? = nil) {
        self.start = start
        self.end = end
        self.isComplete = isComplete
        self.value = value
        self.absoluteCount = absoluteCount
        self.parts = parts
    }
}

public struct TrendSeries: Sendable, Equatable, Identifiable {
    public var identity: TrendSeriesIdentity
    public var title: String
    /// A stable key; views must map it to colors instead of using series rank.
    public var colorSlot: String
    public var role: TrendSeriesRole
    public var emphasis: TrendSeriesEmphasis
    public var buckets: [TrendBucket]

    public var id: TrendSeriesIdentity { identity }
}

public struct TrendPartSeries: Sendable, Equatable, Identifiable {
    public var part: TrendTokenPart
    public var buckets: [TrendBucket]
    public var id: TrendTokenPart { part }
}

public struct AccessibleTrendRow: Sendable, Equatable, Identifiable {
    public var bucketStart: Date
    public var bucketEnd: Date
    public var cells: [String]
    public var id: Date { bucketStart }
}

public struct AccessibleTrendTable: Sendable, Equatable {
    public var columnTitles: [String]
    public var rows: [AccessibleTrendRow]
}

public struct TrendChart: Sendable, Equatable {
    public var windowSeconds: Int
    public var bucketSeconds: Int
    public var series: [TrendSeries]
    /// Canonical token composition used only for Token Burn stacked bars.
    public var partSeries: [TrendPartSeries]
    public var measurementQuality: MeasurementQuality
    public var dataState: DataState?
    public var coverage: Coverage
    public var sourceAuthority: String
    public var freshness: Freshness
    public var sampleCount: Int
    public var definitionVersion: String
    public var scope: OutputThroughputScope
    public var unavailableReason: UnavailableReasonCode?
    public var recommendedAction: MetricAction?
    public var table: AccessibleTrendTable
}

public struct TrendSnapshot: Sendable, Equatable {
    public var outputThroughput: TrendChart
    public var tokenBurn: TrendChart
    public var calls: TrendChart
    public var generatedAt: Date
    public var sourceHealth: [SourceHealth]
}

public enum TrendColorPalette {
    /// Deterministic FNV-1a keeps a model's color stable as rank changes.
    public static func slotIndex(_ identity: String, count: Int = 10) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

public struct TrendPresentation: Sendable, Equatable {
    public var qualityText: String
    public var dataStateText: String
    public var coverageText: String
    public var sourceAuthorityText: String
    public var freshnessText: String
    public var sampleCountText: String
    public var definitionVersionText: String
    public var scopeText: String
    public var reasonText: String?
    public var actionText: String?
    public var allowsContinuousAnimation: Bool

    public init(chart: TrendChart, reduceMotion: Bool = false) {
        qualityText = chart.measurementQuality.displayLabel
        dataStateText = chart.dataState?.displayLabel ?? "-"
        coverageText = chart.coverage.displayLabel
        sourceAuthorityText = chart.sourceAuthority
        freshnessText = Self.freshness(chart.freshness)
        sampleCountText = "n \(chart.sampleCount)"
        definitionVersionText = chart.definitionVersion
        scopeText = chart.scope == .all ? "All" : "Selected"
        reasonText = chart.unavailableReason?.message
        actionText = chart.recommendedAction?.message
        allowsContinuousAnimation = !reduceMotion
    }

    private static func freshness(_ freshness: Freshness) -> String {
        guard let age = freshness.ageSeconds else { return "No update" }
        let seconds = Int(age.rounded(.down))
        let ageText = seconds < 60 ? "\(seconds)s" : seconds < 3_600 ? "\(seconds / 60)m" : "\(seconds / 3_600)h"
        return "Updated \(ageText) ago\(freshness.isRetained ? " · Retained" : "")"
    }
}

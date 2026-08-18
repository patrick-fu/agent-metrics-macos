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

    public var symbol: String {
        switch self {
        case .inputUncached: "■"
        case .cacheRead: "▣"
        case .cacheWrite: "▤"
        case .outputVisible: "▲"
        case .reasoning: "●"
        }
    }

    public var textureName: String {
        switch self {
        case .inputUncached: "solid"
        case .cacheRead: "grid"
        case .cacheWrite: "stripes"
        case .outputVisible: "triangle"
        case .reasoning: "dots"
        }
    }
}

/// Non-color styling cues exposed to the view layer.
public enum TrendSeriesEmphasis: Sendable, Equatable {
    case normal
    case estimated
    case partial
    case other

    public var accessibilityText: String {
        switch self {
        case .normal: "Exact"
        case .estimated: "Estimated"
        case .partial: "Partial"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .normal: "●"
        case .estimated: "┄"
        case .partial: "╌"
        case .other: "◇"
        }
    }
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

public struct AccessibleTrendColumn: Sendable, Equatable {
    public var title: String
    public var identityLabel: String
    public var emphasisText: String
    public var symbol: String
}

public struct AccessibleTrendRow: Sendable, Equatable, Identifiable {
    public var bucketStart: Date
    public var bucketEnd: Date
    public var cells: [String]
    public var isComplete: Bool
    public var id: Date { bucketStart }

    public init(bucketStart: Date, bucketEnd: Date, cells: [String], isComplete: Bool = true) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.cells = cells
        self.isComplete = isComplete
    }
}

public struct AccessibleTrendTable: Sendable, Equatable {
    public var columnTitles: [String]
    public var columns: [AccessibleTrendColumn]
    public var rows: [AccessibleTrendRow]
    public var qualityText: String
    public var dataStateText: String
    public var coverageText: String

    public init(
        columnTitles: [String],
        rows: [AccessibleTrendRow],
        columns: [AccessibleTrendColumn] = [],
        qualityText: String = "-",
        dataStateText: String = "-",
        coverageText: String = "-"
    ) {
        self.columnTitles = columnTitles
        self.columns = columns
        self.rows = rows
        self.qualityText = qualityText
        self.dataStateText = dataStateText
        self.coverageText = coverageText
    }
}

public struct AccessibleTrendTableCursor: Sendable, Equatable {
    public var rowIndex: Int
    public var columnIndex: Int

    public init(rowIndex: Int = 0, columnIndex: Int = 0) {
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
    }

    public mutating func move(rows: Int, columns: Int, in table: AccessibleTrendTable) {
        rowIndex += rows
        columnIndex += columns
        clamp(to: table)
    }

    public mutating func clamp(to table: AccessibleTrendTable) {
        if table.rows.isEmpty || columnCount(in: table) == 0 {
            rowIndex = 0
            columnIndex = 0
            return
        }
        rowIndex = min(max(rowIndex, 0), table.rows.count - 1)
        columnIndex = min(max(columnIndex, 0), columnCount(in: table) - 1)
    }

    public func announcement(in table: AccessibleTrendTable) -> String {
        cellAccessibility(in: table).value
    }

    public func cellAccessibility(in table: AccessibleTrendTable) -> (label: String, value: String) {
        guard table.rows.indices.contains(rowIndex), columnIndex >= 0, columnIndex < columnCount(in: table) else {
            let empty = "No trend values. Quality \(table.qualityText). State \(table.dataStateText). Coverage \(table.coverageText)."
            return (empty, empty)
        }
        let row = table.rows[rowIndex]
        let column = table.columns.indices.contains(columnIndex) ? table.columns[columnIndex] : nil
        let title = column?.title ?? (table.columnTitles.indices.contains(columnIndex) ? table.columnTitles[columnIndex] : "Series")
        let identity = column?.identityLabel ?? title
        let emphasis = column?.emphasisText ?? ""
        let symbol = column?.symbol ?? ""
        let value = row.cells.indices.contains(columnIndex) ? row.cells[columnIndex] : "—"
        let completeness = row.isComplete ? "complete bucket" : "open bucket"
        let start = Self.utcTimestamp(row.bucketStart)
        let end = Self.utcTimestamp(row.bucketEnd)
        let label = "\(title), \(identity), \(start) to \(end)"
        let spoken = [
            start,
            end,
            title,
            identity,
            value,
            emphasis,
            symbol,
            completeness,
            "Quality \(table.qualityText)",
            "State \(table.dataStateText)",
            "Coverage \(table.coverageText)",
        ].filter { !$0.isEmpty }.joined(separator: ", ")
        return (label, spoken)
    }

    private func columnCount(in table: AccessibleTrendTable) -> Int {
        max(table.columnTitles.count, table.columns.count)
    }

    public static func utcTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
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

public struct TrendSeriesCue: Sendable, Equatable {
    public var title: String
    public var identityLabel: String
    public var text: String
    public var symbol: String
    public var dash: [Int]
    public var endpoint: String
}

public struct TrendPartCue: Sendable, Equatable {
    public var title: String
    public var symbol: String
    public var textureName: String
}

public struct TrendPartRenderPlan: Sendable, Equatable {
    public var title: String
    public var symbol: String
    public var textureName: String
    public var pattern: String
}

public struct TrendIdentityCue: Sendable, Equatable {
    public var symbol: String
    public var dash: [Int]
    public var endpoint: String
}

public enum TrendNonColorCuePalette {
    public static let symbols = ["●", "▲", "■", "◆", "✚", "★", "⬡", "▽", "▤", "◌"]
    public static let dashes: [[Int]] = [
        [], [6, 3], [2, 2], [8, 3, 2, 3], [1, 3], [10, 2], [4, 4], [3, 1, 1, 1], [12, 3], [1, 1],
    ]

    public static func cue(forRawIdentity identity: String) -> TrendIdentityCue {
        let hash = fullHash(identity)
        let symbol = symbols[Int(hash % UInt64(symbols.count))]
        let dash = dashes[Int((hash / 33) % UInt64(dashes.count))]
        return TrendIdentityCue(symbol: symbol, dash: dash, endpoint: identity)
    }

    private static func fullHash(_ identity: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
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
    public var seriesCues: [TrendSeriesCue]
    public var partCues: [TrendPartCue]
    public var partRenderPlans: [TrendPartRenderPlan]

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
        seriesCues = chart.series.map { series in
            let raw = series.identity.accessibilityLabel
            let derived = TrendNonColorCuePalette.cue(forRawIdentity: raw)
            return TrendSeriesCue(
                title: series.title,
                identityLabel: raw,
                text: series.emphasis.accessibilityText,
                symbol: series.emphasis == .normal ? derived.symbol : series.emphasis.symbol,
                dash: series.emphasis == .normal ? derived.dash : Self.dash(for: series.emphasis),
                endpoint: raw
            )
        }
        partCues = chart.partSeries.map {
            TrendPartCue(title: $0.part.title, symbol: $0.part.symbol, textureName: $0.part.textureName)
        }
        partRenderPlans = partCues.map {
            TrendPartRenderPlan(title: $0.title, symbol: $0.symbol, textureName: $0.textureName, pattern: $0.textureName)
        }
    }

    private static func dash(for emphasis: TrendSeriesEmphasis) -> [Int] {
        switch emphasis {
        case .estimated: [4, 3]
        case .partial: [1, 2]
        case .other: [6, 2]
        case .normal: []
        }
    }

    private static func endpoint(for emphasis: TrendSeriesEmphasis) -> String {
        switch emphasis {
        case .other: "square"
        case .estimated: "circle"
        case .partial: "circle"
        case .normal: "circle"
        }
    }

    private static func freshness(_ freshness: Freshness) -> String {
        guard let age = freshness.ageSeconds else { return "No update" }
        let seconds = Int(age.rounded(.down))
        let ageText = seconds < 60 ? "\(seconds)s" : seconds < 3_600 ? "\(seconds / 60)m" : "\(seconds / 3_600)h"
        return "Updated \(ageText) ago\(freshness.isRetained ? " · Retained" : "")"
    }
}

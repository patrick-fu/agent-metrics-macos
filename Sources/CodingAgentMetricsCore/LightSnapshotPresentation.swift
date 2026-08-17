import Foundation

public struct FilterChip: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isSelected: Bool

    public init(id: String, title: String, isSelected: Bool) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
    }
}

public struct LightSnapshotPresentation: Sendable, Equatable {
    public var title: String
    public var windowLabel: String
    public var valueText: String
    public var unitText: String
    public var qualityText: String
    public var dataStateText: String
    public var coverageText: String
    public var agentChips: [FilterChip]
    public var modelChips: [FilterChip]

    public init(snapshot: LightSnapshot) {
        title = "Output Throughput"
        windowLabel = "3m"
        unitText = "tokens/s"
        if let tokensPerSecond = snapshot.outputThroughput.tokensPerSecond {
            valueText = Self.format(tokensPerSecond)
        } else {
            valueText = "-"
        }
        qualityText = snapshot.outputThroughput.measurementQuality.displayLabel
        dataStateText = snapshot.outputThroughput.dataState?.displayLabel ?? "-"
        coverageText = snapshot.outputThroughput.coverage.displayLabel
        agentChips = Self.chips(
            axis: "agent",
            allTitle: "All",
            values: snapshot.codingAgents.map { ($0.rawValue, $0.displayName) }
        )
        modelChips = Self.chips(
            axis: "model",
            allTitle: "All",
            values: snapshot.modelIdentities.map { ($0.raw, $0.display) }
        )
    }

    private static func chips(
        axis: String,
        allTitle: String,
        values: [(String, String)]
    ) -> [FilterChip] {
        [FilterChip(id: "all", title: allTitle, isSelected: true)]
            + values.map { FilterChip(id: "\(axis):\($0.0)", title: $0.1, isSelected: false) }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

extension MeasurementQuality {
    var displayLabel: String {
        switch self {
        case .measured: "Measured"
        case .derived: "Derived"
        case .estimated: "Estimated"
        case .unavailable: "Unavailable"
        }
    }
}

extension DataState {
    var displayLabel: String {
        switch self {
        case .zero: "Zero"
        case .stale: "Stale"
        case .absent: "Absent"
        case .unavailable: "Unavailable"
        }
    }
}

extension Coverage {
    var displayLabel: String {
        switch self {
        case .complete: "Complete"
        case .partial: "Partial"
        }
    }
}

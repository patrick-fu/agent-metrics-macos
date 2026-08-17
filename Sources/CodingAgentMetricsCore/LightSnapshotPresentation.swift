import Foundation

public struct FilterChip: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isSelected: Bool
    public var action: FilterChipAction

    public init(id: String, title: String, isSelected: Bool, action: FilterChipAction) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.action = action
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
    public var agentActiveCount: Int
    public var modelActiveCount: Int
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
        agentActiveCount = snapshot.filter.agents.activeCount
        modelActiveCount = snapshot.filter.models.activeCount
        agentChips = Self.chips(
            options: snapshot.codingAgents.map { ($0.rawValue, $0.displayName) },
            axis: snapshot.filter.agents
        )
        modelChips = Self.chips(
            options: snapshot.modelIdentities.map { ($0.raw, $0.display) },
            axis: snapshot.filter.models
        )
    }

    private static func chips(
        options: [(id: String, title: String)],
        axis: SelectionAxis<String>
    ) -> [FilterChip] {
        [FilterChip(id: "all", title: "All", isSelected: axis.isAll, action: .selectAll)]
            + options.map { option in
                FilterChip(
                    id: "value:\(option.id)",
                    title: option.title,
                    isSelected: !axis.isAll && axis.selected.contains(option.id),
                    action: .toggle(option.id)
                )
            }
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

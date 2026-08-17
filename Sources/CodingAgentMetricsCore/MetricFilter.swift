import Foundation

public struct SelectionAxis<Value: Hashable & Sendable>: Sendable, Equatable {
    public private(set) var selected: Set<Value>

    public init(selected: Set<Value> = []) {
        self.selected = selected
    }

    public var isAll: Bool { selected.isEmpty }
    public var activeCount: Int { selected.count }

    public mutating func selectAll() {
        selected.removeAll()
    }

    public mutating func toggle(_ value: Value) {
        if selected.contains(value) {
            selected.remove(value)
        } else {
            selected.insert(value)
        }
    }

    public func contains(_ value: Value) -> Bool {
        isAll || selected.contains(value)
    }
}
public struct MetricFilter: Sendable, Equatable {
    public var agents: SelectionAxis<String>
    public var models: SelectionAxis<String>

    public static let all = MetricFilter()

    public init(
        agents: SelectionAxis<String> = SelectionAxis(),
        models: SelectionAxis<String> = SelectionAxis()
    ) {
        self.agents = agents
        self.models = models
    }

    public func includes(_ fact: UsageFact) -> Bool {
        agents.contains(fact.codingAgent.rawValue) && models.contains(fact.model.raw)
    }
}

public enum FilterAxis: Sendable, Equatable {
    case agent
    case model
}

public enum FilterChipAction: Sendable, Equatable {
    case selectAll
    case toggle(String)
}

extension MetricFilter {
    public mutating func apply(_ action: FilterChipAction, on axis: FilterAxis) {
        switch axis {
        case .agent:
            apply(action, to: &agents)
        case .model:
            apply(action, to: &models)
        }
    }

    private func apply(_ action: FilterChipAction, to axis: inout SelectionAxis<String>) {
        switch action {
        case .selectAll:
            axis.selectAll()
        case .toggle(let value):
            axis.toggle(value)
        }
    }
}

import Foundation

public struct AuthoritySelection: Sendable, Equatable {
    public var facts: [UsageFact]
    public var hasConflict: Bool

    public init(facts: [UsageFact], hasConflict: Bool) {
        self.facts = facts
        self.hasConflict = hasConflict
    }
}

/// Selects one canonical Usage Fact per durable observation identity.
public enum AuthorityCoalescing {
    private struct CohortKey: Hashable {
        var factID: String?
        var capability: String?
        var codingAgent: String?
        var modelCallID: String?
        var granularity: String?
        var rangeStart: TimeInterval?
        var rangeEnd: TimeInterval?

        init(_ fact: UsageFact) {
            guard let modelCallID = fact.modelCallID, !modelCallID.isEmpty else {
                factID = fact.id
                capability = nil
                codingAgent = nil
                self.modelCallID = nil
                granularity = nil
                rangeStart = nil
                rangeEnd = nil
                return
            }
            factID = nil
            capability = fact.modelCallCapability.rawValue
            codingAgent = fact.codingAgent.rawValue
            self.modelCallID = modelCallID
            granularity = fact.measurementGranularity.rawValue
            rangeStart = fact.measurementRange.start.timeIntervalSince1970
            rangeEnd = fact.measurementRange.end.timeIntervalSince1970
        }
    }

    private struct CohortAccumulator {
        var tier: AuthorityTier
        var authority: String
        var representative: UsageFact
        var hasConflict = false
    }

    public static func select(_ facts: [UsageFact]) -> AuthoritySelection {
        var cohorts: [CohortKey: CohortAccumulator] = [:]
        cohorts.reserveCapacity(facts.count)
        for fact in facts {
            let key = CohortKey(fact)
            guard var current = cohorts[key] else {
                cohorts[key] = CohortAccumulator(
                    tier: fact.authorityTier,
                    authority: fact.authority,
                    representative: fact
                )
                continue
            }
            if fact.authorityTier == .enhanced && current.tier == .fallback {
                cohorts[key] = CohortAccumulator(
                    tier: .enhanced,
                    authority: fact.authority,
                    representative: fact
                )
                continue
            }
            guard fact.authorityTier == current.tier else { continue }
            current.hasConflict = current.hasConflict || fact.authority != current.authority
            if fact.id < current.representative.id { current.representative = fact }
            cohorts[key] = current
        }
        let hasConflict = cohorts.values.contains(where: \.hasConflict)
        let selected = cohorts.values
            .filter { !$0.hasConflict }
            .map(\.representative)
            .sorted { $0.id < $1.id }
        return AuthoritySelection(facts: selected, hasConflict: hasConflict)
    }
}

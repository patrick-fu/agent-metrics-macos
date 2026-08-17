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
    public static func select(_ facts: [UsageFact]) -> AuthoritySelection {
        let grouped = Dictionary(grouping: facts) { fact -> String in
            guard let modelCallID = fact.modelCallID, !modelCallID.isEmpty else { return fact.id }
            return [
                fact.modelCallCapability.rawValue,
                fact.codingAgent.rawValue,
                modelCallID,
                fact.measurementGranularity.rawValue,
                String(fact.measurementRange.start.timeIntervalSince1970),
                String(fact.measurementRange.end.timeIntervalSince1970),
            ].joined(separator: ":")
        }
        var selected: [UsageFact] = []
        var hasConflict = false
        for candidates in grouped.values {
            let enhanced = candidates.filter { $0.authorityTier == .enhanced }
            let tierCandidates = enhanced.isEmpty ? candidates : enhanced
            guard Set(tierCandidates.map(\.authority)).count == 1 else {
                hasConflict = true
                continue
            }
            if let representative = tierCandidates.min(by: { $0.id < $1.id }) {
                selected.append(representative)
            }
        }
        return AuthoritySelection(facts: selected.sorted { $0.id < $1.id }, hasConflict: hasConflict)
    }
}

import Foundation

public struct LiveSampler: Sendable {
    public var windowSeconds: Int

    public init(windowSeconds: Int = OutputThroughputDefinition.windowSeconds) {
        self.windowSeconds = windowSeconds
    }

    public func sample(facts: [UsageFact], now: Date) -> LiveSample {
        let start = now.addingTimeInterval(TimeInterval(-windowSeconds))
        let contributing = facts.filter { fact in
            fact.observedAt >= start && fact.observedAt <= now
        }
        let tokens = contributing.reduce(0) { $0 + $1.outputTokens }
        return LiveSample(
            selectedOutputTokens: tokens,
            windowSeconds: windowSeconds,
            contributingFacts: contributing
        )
    }
}

import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct OutputThroughputAggregationTests {
    @Test func twoActiveSessionsYieldAggregateTotalAndPerSessionAverage() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let first = makeFact(sessionID: "s1", outputTokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let second = makeFact(sessionID: "s2", outputTokens: 1_800, observedAt: now.addingTimeInterval(-20))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [first, second], now: now),
            allFacts: [first, second],
            now: now
        )

        #expect(snapshot.outputThroughput.selectedOutputTokens == 3_600)
        #expect(snapshot.outputThroughput.tokensPerSecond == 20)
        #expect(snapshot.outputThroughput.windowSeconds == 180)
        #expect(snapshot.outputThroughput.activeSessionCount == 2)
        #expect(snapshot.outputThroughput.averageTokensPerSecond == 10)
    }

    @Test func oneActiveSessionMakesAggregateEqualAverage() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = makeFact(sessionID: "s1", outputTokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fact], now: now),
            allFacts: [fact],
            now: now
        )
        #expect(snapshot.outputThroughput.tokensPerSecond == 10)
        #expect(snapshot.outputThroughput.activeSessionCount == 1)
        #expect(snapshot.outputThroughput.averageTokensPerSecond == 10)
        #expect(snapshot.outputThroughput.tokensPerSecond == snapshot.outputThroughput.averageTokensPerSecond)
    }

    @Test func liveHeroAndMenuTitleUseAggregateAverageAndActiveCount() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let first = makeFact(sessionID: "s1", outputTokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let second = makeFact(sessionID: "s2", outputTokens: 1_800, observedAt: now.addingTimeInterval(-20))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [first, second], now: now),
            allFacts: [first, second],
            now: now
        )
        let presentation = LightSnapshotPresentation(snapshot: snapshot)
        #expect(presentation.valueText == "20")
        #expect(presentation.averageValueText == "10")
        #expect(presentation.activeSessionsText == "2 active sessions")
        #expect(presentation.menuBarTitleText == "20 t/s")
        #expect(presentation.menuBarAccessibilityLabel.contains("Output Throughput"))
        #expect(presentation.menuBarAccessibilityLabel.contains("20"))
        #expect(presentation.menuBarAccessibilityLabel.contains("10"))
        #expect(presentation.menuBarAccessibilityLabel.contains("2 active sessions"))
        #expect(!presentation.title.localizedCaseInsensitiveContains("TPS"))
    }

    @Test func staleRetainedAndUnavailableMenuTitlesAreEmDashNotLastKnown() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let staleFact = makeFact(sessionID: "s1", outputTokens: 1_800, observedAt: now.addingTimeInterval(-181))
        let stale = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [staleFact], now: now),
            allFacts: [staleFact],
            now: now
        )
        #expect(stale.outputThroughput.tokensPerSecond == 10)
        #expect(stale.outputThroughput.dataState == .stale)
        #expect(stale.outputThroughput.freshness.isRetained)
        #expect(stale.outputThroughput.activeSessionCount == 0)
        #expect(stale.outputThroughput.averageTokensPerSecond == nil)
        let stalePresentation = LightSnapshotPresentation(snapshot: stale)
        #expect(stalePresentation.menuBarTitleText == "—")
        #expect(stalePresentation.menuBarAccessibilityLabel.contains("Output Throughput"))
        #expect(!stalePresentation.menuBarTitleText.contains("10"))

        let empty = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [], now: now),
            allFacts: [],
            now: now
        )
        #expect(empty.outputThroughput.dataState == .absent)
        #expect(LightSnapshotPresentation(snapshot: empty).menuBarTitleText == "—")
    }

    @Test func agentAndModelFiltersKeepAggregateAsSelectedSumAndCountOnlyMatchingSessions() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let codex = makeFact(agent: .codex, sessionID: "s1", modelRaw: "gpt-a", display: "A", outputTokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let claude = makeFact(agent: .claudeCode, sessionID: "s2", modelRaw: "opus", display: "Opus", outputTokens: 1_800, observedAt: now.addingTimeInterval(-20))
        var filter = MetricFilter()
        filter.agents.toggle("codex")
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [codex, claude], filter: filter, now: now),
            allFacts: [codex, claude],
            now: now,
            filter: filter
        )
        #expect(snapshot.outputThroughput.selectedOutputTokens == 1_800)
        #expect(snapshot.outputThroughput.tokensPerSecond == 10)
        #expect(snapshot.outputThroughput.activeSessionCount == 1)
        #expect(snapshot.outputThroughput.averageTokensPerSecond == 10)
    }

    @Test func selectedWindowSecondsAreTheAggregateDenominator() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let recent = makeFact(sessionID: "s1", outputTokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let older = makeFact(sessionID: "s2", outputTokens: 1_800, observedAt: now.addingTimeInterval(-200))
        let three = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler(windowSeconds: 180).sample(facts: [recent, older], now: now),
            allFacts: [recent, older],
            now: now
        )
        #expect(three.outputThroughput.windowSeconds == 180)
        #expect(three.outputThroughput.selectedOutputTokens == 1_800)
        #expect(three.outputThroughput.tokensPerSecond == 10)
        #expect(three.outputThroughput.activeSessionCount == 1)

        let five = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler(windowSeconds: 300).sample(facts: [recent, older], now: now),
            allFacts: [recent, older],
            now: now
        )
        #expect(five.outputThroughput.windowSeconds == 300)
        #expect(five.outputThroughput.selectedOutputTokens == 3_600)
        #expect(five.outputThroughput.tokensPerSecond == 12)
        #expect(five.outputThroughput.activeSessionCount == 2)
        #expect(five.outputThroughput.averageTokensPerSecond == 6)

        let ten = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler(windowSeconds: 600).sample(facts: [recent, older], now: now),
            allFacts: [recent, older],
            now: now
        )
        #expect(ten.outputThroughput.windowSeconds == 600)
        #expect(ten.outputThroughput.tokensPerSecond == 6)
        #expect(LightSnapshotPresentation(snapshot: five).windowLabel == "5m")
        #expect(LightSnapshotPresentation(snapshot: ten).windowLabel == "10m")
    }

    @Test func menuBarTitleUsesCompactThousands() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = makeFact(sessionID: "s1", outputTokens: 216_000, observedAt: now.addingTimeInterval(-10))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fact], now: now),
            allFacts: [fact],
            now: now
        )
        #expect(snapshot.outputThroughput.tokensPerSecond == 1_200)
        #expect(LightSnapshotPresentation(snapshot: snapshot).menuBarTitleText == "1.2k t/s")
    }
}

private func makeFact(
    agent: CodingAgent = .codex,
    sessionID: String,
    modelRaw: String = "gpt-synthetic-orion",
    display: String = "Synthetic Orion",
    outputTokens: Int,
    observedAt: Date
) -> UsageFact {
    UsageFact(
        id: "fact-\(agent.rawValue)-\(sessionID)-\(outputTokens)-\(observedAt.timeIntervalSince1970)",
        schemaVersion: "synthetic-codex-token-count-v1",
        codingAgent: agent,
        model: ModelIdentity(raw: modelRaw, display: display),
        sessionID: sessionID,
        turnID: "turn",
        observedAt: observedAt,
        outputTokens: outputTokens,
        measurementQuality: .measured,
        authority: "synthetic-codex-token-count",
        definitionVersion: OutputThroughputDefinition.version
    )
}

import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct MetricFilterTests {
    @Test func emptySelectionIsAllAndImposesNoConstraint() {
        let axis = SelectionAxis<String>()
        #expect(axis.isAll)
        #expect(axis.activeCount == 0)
        #expect(axis.contains("codex"))
        #expect(axis.contains("claude-code"))
    }

    @Test func togglingUsesORAndDeselectingLastReturnsToAll() {
        var axis = SelectionAxis<String>()
        axis.toggle("codex")
        #expect(!axis.isAll)
        #expect(axis.activeCount == 1)
        #expect(axis.contains("codex"))
        #expect(!axis.contains("claude-code"))

        axis.toggle("claude-code")
        #expect(axis.activeCount == 2)
        #expect(axis.contains("codex"))
        #expect(axis.contains("claude-code"))

        axis.toggle("codex")
        #expect(axis.contains("claude-code"))
        #expect(!axis.contains("codex"))

        axis.toggle("claude-code")
        #expect(axis.isAll)
        #expect(axis.activeCount == 0)
        #expect(axis.contains("codex"))
    }

    @Test func selectingAllClearsExplicitValues() {
        var axis = SelectionAxis<String>(selected: ["codex"])
        axis.selectAll()
        #expect(axis.isAll)
        #expect(axis.activeCount == 0)
    }

    @Test func agentAndModelAxesCombineWithAND() {
        var filter = MetricFilter()
        filter.agents.toggle("codex")
        filter.models.toggle("gpt-4.1")

        #expect(filter.includes(makeFact(agent: .codex, modelRaw: "gpt-4.1", display: "GPT-4.1")))
        #expect(!filter.includes(makeFact(agent: .claudeCode, modelRaw: "gpt-4.1", display: "GPT-4.1")))
        #expect(!filter.includes(makeFact(agent: .codex, modelRaw: "gpt-4.1-preview", display: "GPT-4.1")))
    }

    @Test func modelFilterUsesRawIdentityNotDisplayName() {
        var filter = MetricFilter()
        filter.models.toggle("claude-opus-4")

        #expect(filter.includes(makeFact(agent: .claudeCode, modelRaw: "claude-opus-4", display: "Opus")))
        #expect(!filter.includes(makeFact(agent: .claudeCode, modelRaw: "claude-opus-4-thinking", display: "Opus")))
    }

    @Test func multiSelectThroughputSumsNumeratorsOverCommonWindowInsteadOfAveragingRates() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let codex = makeFact(
            agent: .codex,
            modelRaw: "gpt-a",
            display: "A",
            outputTokens: 180,
            observedAt: now.addingTimeInterval(-10)
        )
        let claude = makeFact(
            agent: .claudeCode,
            modelRaw: "opus",
            display: "Opus",
            outputTokens: 540,
            observedAt: now.addingTimeInterval(-20)
        )
        var filter = MetricFilter()
        filter.agents.toggle("codex")
        filter.agents.toggle("claude-code")

        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [codex, claude], filter: filter, now: now),
            allFacts: [codex, claude],
            now: now,
            filter: filter
        )

        #expect(snapshot.outputThroughput.selectedOutputTokens == 720)
        #expect(snapshot.outputThroughput.tokensPerSecond == 4)
        #expect(snapshot.outputThroughput.windowSeconds == 180)
        #expect(snapshot.outputThroughput.tokensPerSecond != 2)
        #expect(snapshot.filter == filter)
    }
}

private func makeFact(
    agent: CodingAgent,
    modelRaw: String,
    display: String,
    outputTokens: Int = 180,
    observedAt: Date = Date(timeIntervalSince1970: 1_771_200)
) -> UsageFact {
    UsageFact(
        id: "fact-\(agent.rawValue)-\(modelRaw)-\(outputTokens)-\(observedAt.timeIntervalSince1970)",
        schemaVersion: "synthetic-filter-v1",
        codingAgent: agent,
        model: ModelIdentity(raw: modelRaw, display: display),
        sessionID: "session",
        turnID: "turn",
        observedAt: observedAt,
        outputTokens: outputTokens,
        measurementQuality: .measured,
        authority: "synthetic-filter",
        definitionVersion: OutputThroughputDefinition.version
    )
}

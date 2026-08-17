import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct FilteredLightSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_771_200)

    @Test func agentSelectionsProduceCodexOnlyClaudeOnlyAndCombinedFacts() {
        let facts = mixedFacts(now: now)
        let snapshot = build(facts: facts, filter: togglingAgents("codex"))
        #expect(snapshot.outputThroughput.selectedOutputTokens == 540)
        #expect(snapshot.outputThroughput.tokensPerSecond == 3)

        let claude = build(facts: facts, filter: togglingAgents("claude-code"))
        #expect(claude.outputThroughput.selectedOutputTokens == 540)
        #expect(claude.outputThroughput.tokensPerSecond == 3)

        let both = build(facts: facts, filter: togglingAgents("codex", "claude-code"))
        #expect(both.outputThroughput.selectedOutputTokens == 1080)
        #expect(both.outputThroughput.tokensPerSecond == 6)
    }

    @Test func agentAndModelANDExcludesCrossProductMatches() {
        let facts = mixedFacts(now: now)
        var filter = MetricFilter()
        filter.agents.toggle("codex")
        filter.models.toggle("opus")
        let snapshot = build(facts: facts, filter: filter)
        #expect(snapshot.outputThroughput.tokensPerSecond == nil)
        #expect(snapshot.outputThroughput.dataState == .absent)
        #expect(snapshot.codingAgents.map(\.rawValue) == ["claude-code", "codex"])
        #expect(snapshot.modelIdentities.map(\.raw) == ["gpt-a", "gpt-b", "opus"])
    }

    @Test func sameDisplayDifferentRawModelsStayIndependent() {
        let first = makeFact(agent: .claudeCode, modelRaw: "opus-4", display: "Opus", outputTokens: 180, observedAt: now)
        let second = makeFact(agent: .claudeCode, modelRaw: "opus-4-thinking", display: "Opus", outputTokens: 540, observedAt: now)
        var filter = MetricFilter()
        filter.models.toggle("opus-4")
        let snapshot = build(facts: [first, second], filter: filter)
        #expect(snapshot.modelIdentities.map(\.raw) == ["opus-4", "opus-4-thinking"])
        #expect(snapshot.modelIdentities.map(\.display) == ["Opus", "Opus"])
        #expect(snapshot.outputThroughput.selectedOutputTokens == 180)
        #expect(snapshot.outputThroughput.tokensPerSecond == 1)
    }

    @Test func sameRawDifferentDisplayDoesNotSplitTheAxis() {
        let first = makeFact(agent: .codex, modelRaw: "gpt-4.1", display: "GPT-4.1", outputTokens: 180, observedAt: now)
        let second = makeFact(agent: .codex, modelRaw: "gpt-4.1", display: "gpt-4.1-latest", outputTokens: 360, observedAt: now)
        let snapshot = build(facts: [first, second], filter: MetricFilter())
        #expect(snapshot.modelIdentities == [ModelIdentity(raw: "gpt-4.1", display: "GPT-4.1")])
        #expect(snapshot.outputThroughput.selectedOutputTokens == 540)
    }

    @Test func filteredStatesDistinguishZeroStaleAbsentAndUnavailable() {
        let zero = makeFact(agent: .codex, modelRaw: "gpt-a", display: "A", outputTokens: 0, observedAt: now)
        #expect(build(facts: [zero], filter: togglingAgents("codex")).outputThroughput.dataState == .zero)

        let stale = makeFact(agent: .codex, modelRaw: "gpt-a", display: "A", outputTokens: 900, observedAt: now.addingTimeInterval(-181))
        #expect(build(facts: [stale], filter: togglingAgents("codex")).outputThroughput.dataState == .stale)

        let otherAgent = makeFact(agent: .claudeCode, modelRaw: "opus", display: "Opus", outputTokens: 180, observedAt: now)
        let absent = build(facts: [otherAgent], filter: togglingAgents("codex"))
        #expect(absent.outputThroughput.dataState == .absent)
        #expect(absent.outputThroughput.tokensPerSecond == nil)
        #expect(absent.codingAgents.map(\.rawValue) == ["claude-code"])

        let unavailable = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [], filter: togglingAgents("codex"), now: now),
            allFacts: [],
            now: now,
            sourceHealth: [SourceHealth(sourceID: "codex", isHealthy: false, diagnosticCode: "SOURCE_FAILURE")],
            filter: togglingAgents("codex")
        )
        #expect(unavailable.outputThroughput.dataState == .unavailable)
        #expect(unavailable.outputThroughput.coverage == .partial)
    }

    @Test func presentationExposesOptionsActiveCountsAndChipTransitions() {
        let snapshot = build(facts: mixedFacts(now: now), filter: togglingAgents("codex"))
        let presentation = LightSnapshotPresentation(snapshot: snapshot)
        #expect(presentation.agentActiveCount == 1)
        #expect(presentation.modelActiveCount == 0)
        #expect(presentation.agentChips == [
            FilterChip(id: "all", title: "All", isSelected: false, action: .selectAll),
            FilterChip(id: "value:claude-code", title: "Claude Code", isSelected: false, action: .toggle("claude-code")),
            FilterChip(id: "value:codex", title: "Codex", isSelected: true, action: .toggle("codex")),
        ])
        #expect(presentation.modelChips.first == FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll))
        #expect(presentation.modelChips.map(\.id) == ["all", "value:gpt-a", "value:gpt-b", "value:opus"])

        var filter = snapshot.filter
        filter.apply(.toggle("claude-code"), on: .agent)
        #expect(filter.agents.activeCount == 2)
        filter.apply(.toggle("codex"), on: .agent)
        filter.apply(.toggle("claude-code"), on: .agent)
        #expect(filter.agents.isAll)
        filter.apply(.toggle("gpt-a"), on: .model)
        #expect(!filter.models.isAll)
        filter.apply(.selectAll, on: .model)
        #expect(filter.models.isAll)
    }

    @Test func rawModelNamedAllDoesNotCollideWithAllControl() {
        let namedAll = makeFact(agent: .codex, modelRaw: "all", display: "All", outputTokens: 180, observedAt: now)
        let other = makeFact(agent: .codex, modelRaw: "gpt-a", display: "A", outputTokens: 540, observedAt: now)
        let presentation = LightSnapshotPresentation(snapshot: build(facts: [namedAll, other], filter: .all))
        #expect(presentation.modelChips == [
            FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll),
            FilterChip(id: "value:gpt-a", title: "A", isSelected: false, action: .toggle("gpt-a")),
            FilterChip(id: "value:all", title: "All", isSelected: false, action: .toggle("all")),
        ])

        var filter = MetricFilter()
        filter.apply(.toggle("all"), on: .model)
        let selected = build(facts: [namedAll, other], filter: filter)
        #expect(selected.filter.models.selected == Set(["all"]))
        #expect(selected.outputThroughput.selectedOutputTokens == 180)
        #expect(selected.outputThroughput.scope == .selected)
        #expect(!filter.models.isAll)
        filter.apply(.selectAll, on: .model)
        #expect(filter.models.isAll)
    }

    @Test func filteredMetricUsesSelectedScopeInsteadOfAll() {
        let facts = mixedFacts(now: now)
        #expect(build(facts: facts, filter: .all).outputThroughput.scope == .all)
        #expect(build(facts: facts, filter: togglingAgents("codex")).outputThroughput.scope == .selected)
        var models = MetricFilter()
        models.models.toggle("opus")
        #expect(build(facts: facts, filter: models).outputThroughput.scope == .selected)
    }

    @Test func coverageAndUnavailableUseOnlySelectedAgentSources() {
        let facts = mixedFacts(now: now)
        let health = [
            SourceHealth(sourceID: "codex", isHealthy: true),
            SourceHealth(sourceID: "claude-code", isHealthy: false, diagnosticCode: "SOURCE_FAILURE"),
        ]

        let codexOnly = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, filter: togglingAgents("codex"), now: now),
            allFacts: facts,
            now: now,
            sourceHealth: health,
            filter: togglingAgents("codex")
        )
        #expect(codexOnly.outputThroughput.coverage == .complete)
        #expect(codexOnly.outputThroughput.selectedOutputTokens == 540)
        #expect(codexOnly.outputThroughput.dataState == nil)

        let claudeOnly = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [], filter: togglingAgents("claude-code"), now: now),
            allFacts: [],
            now: now,
            sourceHealth: health,
            filter: togglingAgents("claude-code")
        )
        #expect(claudeOnly.outputThroughput.dataState == .unavailable)
        #expect(claudeOnly.outputThroughput.coverage == .partial)
        #expect(claudeOnly.outputThroughput.tokensPerSecond == nil)

        let all = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, now: now),
            allFacts: facts,
            now: now,
            sourceHealth: health
        )
        #expect(all.outputThroughput.coverage == .partial)
        #expect(all.outputThroughput.selectedOutputTokens == 1080)
        #expect(all.outputThroughput.scope == .all)
    }

    @Test func modelOnlyFilterScopesHealthToSourcesThatOwnTheSelectedModel() {
        let facts = mixedFacts(now: now)
        let health = [
            SourceHealth(sourceID: "codex", isHealthy: true),
            SourceHealth(sourceID: "claude-code", isHealthy: false, diagnosticCode: "SOURCE_FAILURE"),
        ]

        var codexModel = MetricFilter()
        codexModel.models.toggle("gpt-a")
        let onlyCodexModel = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, filter: codexModel, now: now),
            allFacts: facts,
            now: now,
            sourceHealth: health,
            filter: codexModel
        )
        #expect(onlyCodexModel.outputThroughput.coverage == .complete)
        #expect(onlyCodexModel.outputThroughput.selectedOutputTokens == 180)
        #expect(onlyCodexModel.outputThroughput.dataState == nil)
        #expect(onlyCodexModel.outputThroughput.scope == .selected)

        var claudeModel = MetricFilter()
        claudeModel.models.toggle("opus")
        let inWindowClaudeModel = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, filter: claudeModel, now: now),
            allFacts: facts,
            now: now,
            sourceHealth: health,
            filter: claudeModel
        )
        #expect(inWindowClaudeModel.outputThroughput.coverage == .partial)
        #expect(inWindowClaudeModel.outputThroughput.selectedOutputTokens == 540)

        let staleClaude = makeFact(
            agent: .claudeCode,
            modelRaw: "opus",
            display: "Opus",
            outputTokens: 540,
            observedAt: now.addingTimeInterval(-181)
        )
        let unavailableClaudeModel = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [staleClaude], filter: claudeModel, now: now),
            allFacts: [staleClaude],
            now: now,
            sourceHealth: health,
            filter: claudeModel
        )
        #expect(unavailableClaudeModel.outputThroughput.dataState == .unavailable)
        #expect(unavailableClaudeModel.outputThroughput.coverage == .partial)
        #expect(unavailableClaudeModel.outputThroughput.tokensPerSecond == nil)
    }

    @Test func optionsSortByDisplayThenRaw() {
        let laterAlpha = makeFact(agent: .codex, modelRaw: "zeta", display: "Zeta", outputTokens: 180, observedAt: now)
        let earlierBeta = makeFact(agent: .claudeCode, modelRaw: "alpha-2", display: "Alpha", outputTokens: 180, observedAt: now)
        let earlierAlpha = makeFact(agent: .claudeCode, modelRaw: "alpha-1", display: "Alpha", outputTokens: 180, observedAt: now)
        let snapshot = build(facts: [laterAlpha, earlierBeta, earlierAlpha], filter: .all)
        #expect(snapshot.codingAgents.map(\.displayName) == ["Claude Code", "Codex"])
        #expect(snapshot.modelIdentities.map(\.raw) == ["alpha-1", "alpha-2", "zeta"])
    }

    @Test func failedFilterLoadKeepsPreviousSnapshotAndFilter() {
        let original = build(facts: mixedFacts(now: now), filter: .all)
        let kept = LightSnapshot.updated(
            from: original,
            applying: .toggle("codex"),
            on: .agent,
            load: { _ in nil }
        )
        #expect(kept == original)
        #expect(kept?.filter.agents.isAll == true)
    }

    @Test func filterOnlySnapshotReusesPersistedFactsWithoutRescanningSources() throws {
        let clock = FixedClock(now: now)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-filter-only-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let incremental = CountingIncrementalAdapter(
            observation: makeObservation(
                agent: .codex,
                modelRaw: "gpt-a",
                display: "A",
                outputTokens: 180,
                observedAt: now.addingTimeInterval(-5)
            )
        )
        let nonIncremental = CountingSourceAdapter(observations: [
            makeObservation(
                agent: .claudeCode,
                modelRaw: "opus",
                display: "Opus",
                outputTokens: 540,
                observedAt: now.addingTimeInterval(-5)
            )
        ])
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapters: [incremental, nonIncremental],
            clock: clock
        )

        let first = try runtime.lightSnapshot()
        #expect(incremental.scanCount == 1)
        #expect(incremental.loadCount == 0)
        #expect(nonIncremental.loadCount == 0)
        #expect(first.outputThroughput.selectedOutputTokens == 180)

        var filter = MetricFilter()
        filter.agents.toggle("codex")
        let second = try runtime.lightSnapshotFromStore(filter: filter)
        let third = try runtime.lightSnapshotFromStore(filter: .all)
        #expect(incremental.scanCount == 1)
        #expect(incremental.loadCount == 0)
        #expect(nonIncremental.loadCount == 0)
        #expect(second.outputThroughput.selectedOutputTokens == 180)
        #expect(second.filter.agents.selected == Set(["codex"]))
        #expect(third.outputThroughput.selectedOutputTokens == 180)
        #expect(third.filter.agents.isAll)
    }

    @Test func runtimeAppliesFilterWhileKeepingUnfilteredOptions() throws {
        let clock = FixedClock(now: now)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-filter-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: FixedSourceAdapter(observations: [
                makeObservation(agent: .codex, modelRaw: "gpt-a", display: "A", outputTokens: 180, observedAt: now.addingTimeInterval(-5)),
                makeObservation(agent: .claudeCode, modelRaw: "opus", display: "Opus", outputTokens: 540, observedAt: now.addingTimeInterval(-5)),
            ]),
            clock: clock
        )

        let all = try runtime.lightSnapshot()
        #expect(all.outputThroughput.selectedOutputTokens == 720)
        #expect(Set(all.codingAgents.map(\.rawValue)) == Set(["codex", "claude-code"]))

        let filtered = try runtime.lightSnapshot(filter: togglingAgents("codex"))
        #expect(filtered.outputThroughput.selectedOutputTokens == 180)
        #expect(filtered.outputThroughput.tokensPerSecond == 1)
        #expect(filtered.filter.agents.selected == Set(["codex"]))
        #expect(Set(filtered.codingAgents.map(\.rawValue)) == Set(["codex", "claude-code"]))
        #expect(Set(filtered.modelIdentities.map(\.raw)) == Set(["gpt-a", "opus"]))
    }
}

private func togglingAgents(_ rawValues: String...) -> MetricFilter {
    var filter = MetricFilter()
    for rawValue in rawValues {
        filter.agents.toggle(rawValue)
    }
    return filter
}

private func build(facts: [UsageFact], filter: MetricFilter) -> LightSnapshot {
    let now = Date(timeIntervalSince1970: 1_771_200)
    return SnapshotBuilder().buildLightSnapshot(
        sample: LiveSampler().sample(facts: facts, filter: filter, now: now),
        allFacts: facts,
        now: now,
        filter: filter
    )
}

private func mixedFacts(now: Date) -> [UsageFact] {
    [
        makeFact(agent: .codex, modelRaw: "gpt-a", display: "A", outputTokens: 180, observedAt: now.addingTimeInterval(-10)),
        makeFact(agent: .codex, modelRaw: "gpt-b", display: "B", outputTokens: 360, observedAt: now.addingTimeInterval(-20)),
        makeFact(agent: .claudeCode, modelRaw: "opus", display: "Opus", outputTokens: 540, observedAt: now.addingTimeInterval(-30)),
    ]
}

private func makeFact(
    agent: CodingAgent,
    modelRaw: String,
    display: String,
    outputTokens: Int,
    observedAt: Date
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

private func makeObservation(
    agent: CodingAgent,
    modelRaw: String,
    display: String,
    outputTokens: Int,
    observedAt: Date
) -> UsageObservation {
    UsageObservation(
        observationIdentity: "obs-\(agent.rawValue)-\(modelRaw)-\(outputTokens)",
        schemaVersion: "synthetic-filter-v1",
        codingAgent: agent,
        model: ModelIdentity(raw: modelRaw, display: display),
        sessionID: "session",
        turnID: "turn",
        observedAt: observedAt,
        outputTokens: outputTokens
    )
}

private struct FixedSourceAdapter: SourceAdapter {
    let observations: [UsageObservation]
    func loadObservations(clock: any Clock) throws -> [UsageObservation] { observations }
}

private final class CountingSourceAdapter: SourceAdapter, @unchecked Sendable {
    let observations: [UsageObservation]
    var loadCount = 0
    init(observations: [UsageObservation]) { self.observations = observations }
    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        loadCount += 1
        return observations
    }
}

private final class CountingIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let observation: UsageObservation
    var scanCount = 0
    var loadCount = 0
    init(observation: UsageObservation) { self.observation = observation }
    var sourceID: String { "codex" }
    var sourceRebuildScope: SourceFactScope { .schemaVersion("synthetic-filter-v1") }
    func rebuiltFileScope(for identity: String) -> SourceFactScope { .idPrefix(identity) }
    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        loadCount += 1
        return [observation]
    }
    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        scanCount += 1
        return SourceScan(
            observations: [observation],
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: false,
            health: SourceHealth(sourceID: sourceID, isHealthy: true)
        )
    }
}

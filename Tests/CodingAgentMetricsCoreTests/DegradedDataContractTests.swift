import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

struct DegradedDataContractTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func degradedMetadataContractsKeepStateQualityCoverageAndStableRecoveryGuidanceOrthogonal() throws {
        let freshness = Freshness(
            lastUpdatedAt: Date(timeIntervalSince1970: 100),
            ageSeconds: 20,
            isRetained: true
        )

        #expect(freshness.isRetained)
        #expect(UnavailableReasonCode.requestTimingUnavailable.rawValue == "REQUEST_TIMING_UNAVAILABLE")
        #expect(MetricAction.enableEnhancedTelemetry.rawValue == "ENABLE_ENHANCED_TELEMETRY")
        #expect(MeasurementQuality.estimated != .unavailable)
        #expect(DataState.stale != .unavailable)
        #expect(Coverage.partial != .complete)

        let encoded = try JSONEncoder().encode(freshness)
        #expect(try JSONDecoder().decode(Freshness.self, from: encoded) == freshness)
    }

    @Test func everyStateQualityCoverageAndRecoveryCombinationRemainsRepresentable() {
        let states: [DataState] = [.zero, .stale, .absent, .unavailable]
        let qualities: [MeasurementQuality] = [.measured, .derived, .estimated, .unavailable]
        let coverages: [Coverage] = [.complete, .partial]
        let recoveries: [(UnavailableReasonCode, MetricAction)] = [
            (.noObservations, .waitForObservations),
            (.filterExcludesObservations, .reduceFilter),
            (.unsupportedSchema, .updateSource),
            (.requestTimingUnavailable, .enableEnhancedTelemetry),
        ]
        var combinationCount = 0

        for state in states {
            for quality in qualities {
                for coverage in coverages {
                    for (reason, action) in recoveries {
                        let presentation = MetricMetadataPresentation(
                            quality: quality,
                            state: state,
                            coverage: coverage,
                            freshness: .unavailable,
                            sampleCount: 0,
                            definitionVersion: "test-v1",
                            sourceAuthority: "test-source",
                            scope: .selected,
                            unavailableReason: reason,
                            recommendedAction: action
                        )

                        #expect(presentation.qualityText == quality.displayLabel)
                        #expect(presentation.stateText == state.displayLabel)
                        #expect(presentation.coverageText == coverage.displayLabel)
                        #expect(presentation.reasonText == reason.message)
                        #expect(presentation.actionText == action.message)
                        combinationCount += 1
                    }
                }
            }
        }

        #expect(combinationCount == 128)
    }

    @Test func legacyAbsentRawValueStillDecodesWhilePresentationSaysNoData() throws {
        let decoded = try JSONDecoder().decode(DataState.self, from: Data(#""absent""#.utf8))

        #expect(decoded == .absent)
        #expect(decoded.displayLabel == "No data")
    }

    @Test func legacySourceHealthDecodesWithConservativeUsageImpact() throws {
        let payload = Data(#"{"sourceID":"legacy","isHealthy":false,"diagnosticCode":"SOURCE_FAILURE"}"#.utf8)
        let health = try JSONDecoder().decode(SourceHealth.self, from: payload)

        #expect(health.impacts == [.usage])
        #expect(health.reasonCode == .sourceFailure)
        #expect(health.recommendedAction == .updateSource)
    }

    @Test func mixedMeasuredAndEstimatedUsageKeepsEverySampleAndLowersTruthfulQuality() {
        let measured = fact(id: "measured", quality: .measured, observedAt: now.addingTimeInterval(-2), output: 180)
        let estimated = fact(id: "estimated", quality: .estimated, observedAt: now.addingTimeInterval(-1), output: 360)
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [measured, estimated], now: now),
            allFacts: [measured, estimated],
            now: now
        )

        #expect(snapshot.outputThroughput.selectedOutputTokens == 540)
        #expect(snapshot.outputThroughput.measurementQuality == .estimated)
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(snapshot.outputThroughput.sampleCount == 2)
        #expect(snapshot.outputThroughput.freshness == .observed(at: estimated.observedAt, now: now))

        #expect(snapshot.tokenBurn.selectedBurnTokens == 540)
        #expect(snapshot.tokenBurn.measurementQuality == .estimated)
        #expect(snapshot.tokenBurn.coverage == .partial)
        #expect(snapshot.calls.selectedCallCount == 2)
        #expect(snapshot.calls.measurementQuality == .estimated)
        #expect(snapshot.calls.coverage == .partial)
    }

    @Test func staleUsageRetainsLastGoodValuesAndAgeWithSourceScopedReason() {
        let old = fact(id: "old", quality: .measured, observedAt: now.addingTimeInterval(-601), output: 600)
        let health = SourceHealth(
            sourceID: "source-a",
            isHealthy: false,
            diagnosticCode: "SOURCE_UNAVAILABLE",
            impacts: [.usage],
            impactedAgents: [.codex],
            impactedChannels: [.synthetic]
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [old], now: now),
            allFacts: [old],
            now: now,
            sourceHealth: [health]
        )

        #expect(snapshot.outputThroughput.tokensPerSecond == 600.0 / 180.0)
        #expect(snapshot.outputThroughput.dataState == .stale)
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(snapshot.outputThroughput.freshness == .observed(at: old.observedAt, now: now, retained: true))
        #expect(snapshot.outputThroughput.unavailableReason == .sourceUnavailable)
        #expect(snapshot.outputThroughput.recommendedAction == .updateSource)

        #expect(snapshot.tokenBurn.tokensPerMinute == 60)
        #expect(snapshot.tokenBurn.dataState == .stale)
        #expect(snapshot.calls.callsPerMinute == 0.1)
        #expect(snapshot.calls.dataState == .stale)
    }

    @Test func currentFactsFromAnOverloadedSourceStayFreshWhileExposingPartialCoverage() {
        let current = fact(id: "current", quality: .measured, observedAt: now.addingTimeInterval(-1), output: 180)
        let health = SourceHealth(
            sourceID: "source-a",
            isHealthy: false,
            diagnosticCode: "SOURCE_OVERLOADED",
            impacts: [.usage],
            impactedAgents: [.codex],
            impactedChannels: [.synthetic]
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [current], now: now),
            allFacts: [current],
            now: now,
            sourceHealth: [health]
        )

        #expect(snapshot.outputThroughput.selectedOutputTokens == 180)
        #expect(snapshot.outputThroughput.averageTokensPerSecond == 1)
        #expect(snapshot.outputThroughput.activeSessionCount == 1)
        #expect(snapshot.outputThroughput.dataState == nil)
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(!snapshot.outputThroughput.freshness.isRetained)
        #expect(snapshot.outputThroughput.unavailableReason == .sourceOverloaded)
        #expect(snapshot.outputThroughput.recommendedAction == .updateSource)

        #expect(snapshot.tokenBurn.selectedBurnTokens == 180)
        #expect(snapshot.tokenBurn.dataState == nil)
        #expect(snapshot.tokenBurn.coverage == .partial)
        #expect(!snapshot.tokenBurn.freshness.isRetained)
        #expect(snapshot.tokenBurn.unavailableReason == .sourceOverloaded)
        #expect(snapshot.tokenBurn.recommendedAction == .updateSource)

        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.calls.dataState == nil)
        #expect(snapshot.calls.coverage == .partial)
        #expect(!snapshot.calls.freshness.isRetained)
        #expect(snapshot.calls.unavailableReason == .sourceOverloaded)
        #expect(snapshot.calls.recommendedAction == .updateSource)

        let presentation = LightSnapshotPresentation(snapshot: snapshot)
        #expect(presentation.valueText == "1")
        #expect(presentation.averageValueText == "1")
        #expect(presentation.menuBarTitleText == "1 t/s")
    }

    @Test func currentSourceExcludesAnotherSourcesRetainedFactsFromTheLiveAggregate() {
        let oldSourceA = fact(
            id: "old-source-a", quality: .measured, observedAt: now.addingTimeInterval(-601), output: 180,
            sourceID: "source-a", agent: .codex
        )
        let currentSourceB = fact(
            id: "current-source-b", quality: .measured, observedAt: now.addingTimeInterval(-1), output: 360,
            sourceID: "source-b", agent: .claudeCode
        )
        let failedSourceA = SourceHealth(
            sourceID: "source-a",
            isHealthy: false,
            diagnosticCode: "SOURCE_OVERLOADED",
            impacts: [.usage],
            impactedAgents: [.codex],
            impactedChannels: [.synthetic]
        )

        let all = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [oldSourceA, currentSourceB], now: now),
            allFacts: [oldSourceA, currentSourceB],
            now: now,
            sourceHealth: [failedSourceA]
        )
        #expect(all.outputThroughput.selectedOutputTokens == 360)
        #expect(all.outputThroughput.averageTokensPerSecond == 2)
        #expect(all.outputThroughput.activeSessionCount == 1)
        #expect(all.outputThroughput.dataState == nil)
        #expect(all.outputThroughput.coverage == .partial)
        #expect(!all.outputThroughput.freshness.isRetained)
        #expect(all.outputThroughput.unavailableReason == .sourceOverloaded)
        #expect(all.outputThroughput.recommendedAction == .updateSource)
        #expect(all.tokenBurn.selectedBurnTokens == 360)
        #expect(all.tokenBurn.dataState == nil)
        #expect(all.tokenBurn.coverage == .partial)
        #expect(!all.tokenBurn.freshness.isRetained)
        #expect(all.tokenBurn.unavailableReason == .sourceOverloaded)
        #expect(all.tokenBurn.recommendedAction == .updateSource)
        #expect(all.calls.selectedCallCount == 1)
        #expect(all.calls.dataState == nil)
        #expect(all.calls.coverage == .partial)
        #expect(!all.calls.freshness.isRetained)
        #expect(all.calls.unavailableReason == .sourceOverloaded)
        #expect(all.calls.recommendedAction == .updateSource)
        #expect(LightSnapshotPresentation(snapshot: all).valueText == "2")
        #expect(LightSnapshotPresentation(snapshot: all).menuBarTitleText == "2 t/s")

        var onlyAFilter = MetricFilter()
        onlyAFilter.agents.toggle("codex")
        let onlyA = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [oldSourceA, currentSourceB], filter: onlyAFilter, now: now),
            allFacts: [oldSourceA, currentSourceB],
            now: now,
            sourceHealth: [failedSourceA],
            filter: onlyAFilter
        )
        #expect(onlyA.outputThroughput.selectedOutputTokens == 180)
        #expect(onlyA.outputThroughput.dataState == .stale)
        #expect(onlyA.outputThroughput.freshness.isRetained)
        #expect(LightSnapshotPresentation(snapshot: onlyA).menuBarTitleText == "—")

        var onlyBFilter = MetricFilter()
        onlyBFilter.agents.toggle("claude-code")
        let onlyB = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [oldSourceA, currentSourceB], filter: onlyBFilter, now: now),
            allFacts: [oldSourceA, currentSourceB],
            now: now,
            sourceHealth: [failedSourceA],
            filter: onlyBFilter
        )
        #expect(onlyB.outputThroughput.selectedOutputTokens == 360)
        #expect(onlyB.outputThroughput.dataState == nil)
        #expect(onlyB.outputThroughput.coverage == .complete)
        #expect(!onlyB.outputThroughput.freshness.isRetained)
    }

    @Test func noFactsAndFilteredFactsExposeStableReasonsAndActions() {
        let empty = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [], now: now), allFacts: [], now: now
        )
        #expect(empty.outputThroughput.dataState == .absent)
        #expect(empty.outputThroughput.unavailableReason == .noObservations)
        #expect(empty.outputThroughput.recommendedAction == .waitForObservations)

        var filter = MetricFilter()
        filter.agents.toggle("claude-code")
        let existing = fact(id: "codex", quality: .measured, observedAt: now, output: 180)
        let filtered = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [existing], filter: filter, now: now),
            allFacts: [existing],
            now: now,
            filter: filter
        )
        #expect(filtered.outputThroughput.dataState == .absent)
        #expect(filtered.outputThroughput.unavailableReason == .filterExcludesObservations)
        #expect(filtered.outputThroughput.recommendedAction == .reduceFilter)
    }

    @Test func performanceMixedQualityKeepsPooledSamplesAndAllDistributionMetadata() {
        let measured = performanceFact(id: "measured", quality: .measured, observedAt: now.addingTimeInterval(-2))
        let estimated = performanceFact(id: "estimated", quality: .estimated, observedAt: now.addingTimeInterval(-1))
        let snapshot = PerformanceSnapshotBuilder().build(facts: [measured, estimated], now: now)

        for distribution in [snapshot.timeToFirstToken, snapshot.endToEnd, snapshot.decodeTPS] {
            #expect(distribution.sampleCount == 2)
            #expect(distribution.measurementQuality == .estimated)
            #expect(distribution.coverage == .partial)
            #expect(distribution.freshness == .observed(at: estimated.observedAt, now: now))
            #expect(distribution.sourceAuthority == "performance-a")
            #expect(distribution.scope == .all)
            #expect(distribution.definitionVersion.isEmpty == false)
            #expect(distribution.isLowSample)
        }

        let empty = PerformanceSnapshotBuilder().build(facts: [], now: now)
        for (kind, distribution) in [
            (PerformanceMetricKind.timeToFirstToken, empty.timeToFirstToken),
            (.endToEnd, empty.endToEnd),
            (.decodeTPS, empty.decodeTPS),
        ] {
            #expect(distribution.sampleCount == 0)
            #expect(!distribution.isLowSample)
            #expect(PerformanceMetricPresentation(kind: kind, distribution: distribution).secondaryText.contains("n 0"))
        }
    }

    @Test func performanceHealthIsSourceScopedAndRetainsAffectedLastGoodDistribution() {
        let sourceA = performanceFact(
            id: "a", quality: .measured, observedAt: now.addingTimeInterval(-3_601),
            sourceID: "performance-a", agent: .codex
        )
        let sourceB = performanceFact(
            id: "b", quality: .measured, observedAt: now.addingTimeInterval(-1),
            sourceID: "performance-b", agent: .claudeCode
        )
        let failedA = SourceHealth(
            sourceID: "performance-a",
            isHealthy: false,
            diagnosticCode: "SOURCE_FAILURE",
            impacts: [.performance],
            impactedAgents: [.codex],
            impactedChannels: [.claudeTelemetry]
        )

        var codex = MetricFilter()
        codex.agents.toggle("codex")
        let retained = PerformanceSnapshotBuilder().build(
            facts: [sourceA, sourceB], now: now, filter: codex, sourceHealth: [failedA]
        )
        #expect(retained.timeToFirstToken.p50 == 100)
        #expect(retained.timeToFirstToken.dataState == .stale)
        #expect(retained.timeToFirstToken.coverage == .partial)
        #expect(retained.timeToFirstToken.freshness.isRetained)
        #expect(retained.timeToFirstToken.unavailableReason == .sourceFailure)

        var claude = MetricFilter()
        claude.agents.toggle("claude-code")
        let healthy = PerformanceSnapshotBuilder().build(
            facts: [sourceA, sourceB], now: now, filter: claude, sourceHealth: [failedA]
        )
        #expect(healthy.timeToFirstToken.p50 == 100)
        #expect(healthy.timeToFirstToken.dataState == nil)
        #expect(healthy.timeToFirstToken.coverage == .complete)
        #expect(!healthy.timeToFirstToken.freshness.isRetained)
    }

    @Test func failedSourceWithoutLastGoodMakesCombinedCoveragePartialButLeavesHealthyValuesFresh() {
        let usageB = fact(
            id: "usage-b", quality: .measured, observedAt: now.addingTimeInterval(-1), output: 360,
            sourceID: "source-b", agent: .claudeCode
        )
        let performanceB = performanceFact(
            id: "performance-b", quality: .measured, observedAt: now.addingTimeInterval(-1),
            sourceID: "performance-b", agent: .claudeCode
        )
        let failedUsageA = SourceHealth(
            sourceID: "source-a", isHealthy: false, diagnosticCode: "SOURCE_FAILURE",
            impacts: [.usage], impactedAgents: [.codex], impactedChannels: [.synthetic]
        )
        let failedPerformanceA = SourceHealth(
            sourceID: "performance-a", isHealthy: false, diagnosticCode: "SOURCE_FAILURE",
            impacts: [.performance], impactedAgents: [.codex], impactedChannels: [.claudeTelemetry]
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [usageB], now: now),
            allFacts: [usageB],
            performanceFacts: [performanceB],
            now: now,
            sourceHealth: [failedUsageA, failedPerformanceA]
        )

        #expect(snapshot.outputThroughput.selectedOutputTokens == 360)
        #expect(snapshot.outputThroughput.dataState == nil)
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(!snapshot.outputThroughput.freshness.isRetained)
        #expect(snapshot.outputThroughput.unavailableReason == .sourceFailure)

        #expect(snapshot.performance.timeToFirstToken.p50 == 100)
        #expect(snapshot.performance.timeToFirstToken.dataState == nil)
        #expect(snapshot.performance.timeToFirstToken.coverage == .partial)
        #expect(!snapshot.performance.timeToFirstToken.freshness.isRetained)
        #expect(snapshot.performance.timeToFirstToken.unavailableReason == .sourceFailure)
    }

    @Test func modelOnlyFilterWithoutFactsKeepsExplicitSourceFailuresVisible() {
        var modelOnly = MetricFilter()
        modelOnly.models.toggle("missing-model")
        let usageFailure = SourceHealth(
            sourceID: "source-a", isHealthy: false, diagnosticCode: "SOURCE_FAILURE",
            impacts: [.usage], impactedAgents: [.codex], impactedChannels: [.synthetic]
        )
        let performanceFailure = SourceHealth(
            sourceID: "performance-a", isHealthy: false, diagnosticCode: "SOURCE_FAILURE",
            impacts: [.performance], impactedAgents: [.codex], impactedChannels: [.claudeTelemetry]
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [], filter: modelOnly, now: now),
            allFacts: [],
            performanceFacts: [],
            now: now,
            sourceHealth: [usageFailure, performanceFailure],
            filter: modelOnly
        )

        #expect(snapshot.outputThroughput.dataState == .unavailable)
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(snapshot.outputThroughput.unavailableReason == .sourceFailure)
        #expect(snapshot.performance.timeToFirstToken.coverage == .partial)
        #expect(snapshot.performance.timeToFirstToken.unavailableReason == .sourceFailure)
    }

    @Test func explicitSourceOwnershipAndPerformanceQualitySurviveSQLiteRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("degraded-source-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = fact(id: "usage", quality: .estimated, observedAt: now, output: 12, sourceID: "usage-a")
        let performance = performanceFact(
            id: "performance", quality: .estimated, observedAt: now,
            sourceID: "performance-a", agent: .claudeCode
        )
        let store = try SQLiteFactStore(url: url)

        try store.upsert([usage])
        try store.upsertPerformanceFacts([performance])

        #expect(try store.allFacts().first?.sourceID == "usage-a")
        #expect(try store.allPerformanceFacts().first?.sourceID == "performance-a")
        #expect(try store.allPerformanceFacts().first?.measurementQuality == .estimated)
    }

    @Test func legacyUsageMigrationBackfillsKnownSourceIDWithoutGuessingAgent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("degraded-legacy-source-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let schema = """
            CREATE TABLE usage_facts (
                id TEXT PRIMARY KEY, schema_version TEXT NOT NULL,
                coding_agent_raw TEXT NOT NULL, coding_agent_display TEXT NOT NULL,
                model_raw TEXT NOT NULL, model_display TEXT NOT NULL,
                session_id TEXT NOT NULL, turn_id TEXT NOT NULL,
                observed_at REAL NOT NULL, output_tokens INTEGER NOT NULL,
                measurement_quality TEXT NOT NULL, authority TEXT NOT NULL,
                definition_version TEXT NOT NULL
            );
            INSERT INTO usage_facts VALUES (
                'legacy-codex', 'codex-rollout-v1', 'codex', 'Codex', 'model', 'Model',
                'session', 'turn', \(now.timeIntervalSince1970), 180,
                'measured', 'codex-rollout-local', 'output-throughput-v1'
            );
            """
        #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let store = try SQLiteFactStore(url: url)
        #expect(try store.allFacts().first?.sourceID == "codex")
        #expect(try store.latestObservedAt(sourceID: "codex", before: now) == now)
    }

    @Test func runtimeRetainsOnlyFailedSourceWhileHealthySourceContinuesFresh() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("degraded-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = MutableTestClock(now: now)
        let sourceA = FlakyOwnedAdapter(
            ownership: SourceOwnership(
                sourceID: "source-a", impacts: [.usage], codingAgents: [.codex], channels: [.synthetic]
            ),
            output: 180,
            failsAfterFirstScan: true
        )
        let sourceB = FlakyOwnedAdapter(
            ownership: SourceOwnership(
                sourceID: "source-b", impacts: [.usage], codingAgents: [.claudeCode], channels: [.synthetic]
            ),
            output: 360,
            failsAfterFirstScan: false
        )
        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [sourceA, sourceB], clock: clock)
        _ = try runtime.lightSnapshot()
        clock.now = now.addingTimeInterval(601)

        let combined = try runtime.lightSnapshot()
        #expect(runtime.sourceHealth.contains { $0.sourceID == "source-a" && !$0.isHealthy })
        #expect(try SQLiteFactStore(url: url).allFacts().map(\.sourceID).contains("source-a"))
        #expect(combined.outputThroughput.selectedOutputTokens == 360)
        #expect(combined.outputThroughput.dataState == nil)
        #expect(combined.outputThroughput.coverage == .partial)
        #expect(!combined.outputThroughput.freshness.isRetained)

        var onlyB = MetricFilter()
        onlyB.agents.toggle("claude-code")
        let healthy = try runtime.lightSnapshot(filter: onlyB)
        #expect(healthy.outputThroughput.selectedOutputTokens == 360)
        #expect(healthy.outputThroughput.dataState == nil)
        #expect(healthy.outputThroughput.coverage == .complete)

        var onlyA = MetricFilter()
        onlyA.agents.toggle("codex")
        let retained = try runtime.lightSnapshot(filter: onlyA)
        #expect(retained.outputThroughput.selectedOutputTokens == 180)
        #expect(retained.outputThroughput.dataState == .stale)
        #expect(retained.outputThroughput.freshness.isRetained)
    }

    @Test func legacyAdaptersWithoutOwnershipNeverRetainAnotherUnknownSourcesFacts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("degraded-legacy-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = MutableTestClock(now: now)
        let sourceA = LegacyFlakyAdapter(
            sourceID: "legacy-a", agent: .codex, output: 180, failsAfterFirstScan: true
        )
        let sourceB = LegacyFlakyAdapter(
            sourceID: "legacy-b", agent: .claudeCode, output: 360, failsAfterFirstScan: false
        )
        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [sourceA, sourceB], clock: clock)
        _ = try runtime.lightSnapshot()
        clock.now = now.addingTimeInterval(601)

        let combined = try runtime.lightSnapshot()
        #expect(combined.outputThroughput.selectedOutputTokens == 360)
        #expect(combined.outputThroughput.dataState == nil)
        #expect(combined.outputThroughput.coverage == .partial)
        #expect(!combined.outputThroughput.freshness.isRetained)

        var onlyB = MetricFilter()
        onlyB.agents.toggle("claude-code")
        let healthyB = try runtime.lightSnapshot(filter: onlyB)
        #expect(healthyB.outputThroughput.selectedOutputTokens == 360)
        #expect(healthyB.outputThroughput.dataState == nil)
        #expect(healthyB.outputThroughput.coverage == .complete)
        #expect(!healthyB.outputThroughput.freshness.isRetained)
    }

    @Test func trendMetadataMarksMixedQualityAndSourceHealthWithoutDroppingSamples() {
        let measured = fact(id: "trend-measured", quality: .measured, observedAt: now.addingTimeInterval(-2), output: 180)
        let estimated = fact(id: "trend-estimated", quality: .estimated, observedAt: now.addingTimeInterval(-1), output: 360)
        let chart = TrendBuilder().build(facts: [measured, estimated], now: now).outputThroughput

        #expect(chart.measurementQuality == .estimated)
        #expect(chart.coverage == .partial)
        #expect(chart.sampleCount == 2)
        #expect(chart.freshness == .observed(at: estimated.observedAt, now: now))
        #expect(chart.definitionVersion == OutputThroughputDefinition.version)
        #expect(chart.scope == .all)
        #expect(chart.series.first?.emphasis == .estimated)

        let presentation = TrendPresentation(chart: chart)
        #expect(presentation.sourceAuthorityText == "synthetic")
        #expect(presentation.sampleCountText == "n 2")
        #expect(presentation.definitionVersionText == OutputThroughputDefinition.version)
        #expect(presentation.freshnessText.contains("Updated"))
    }

    @Test func trendHealthDegradesOnlyTheOwnedSourceAndRetainsItsSeries() {
        let sourceA = fact(
            id: "trend-a", quality: .measured, observedAt: now.addingTimeInterval(-2), output: 180,
            sourceID: "source-a", agent: .codex
        )
        let sourceB = fact(
            id: "trend-b", quality: .measured, observedAt: now.addingTimeInterval(-1), output: 360,
            sourceID: "source-b", agent: .claudeCode
        )
        let failedA = SourceHealth(
            sourceID: "source-a", isHealthy: false, diagnosticCode: "SOURCE_OVERLOADED",
            impacts: [.usage], impactedAgents: [.codex], impactedChannels: [.synthetic]
        )
        let combined = TrendBuilder().build(
            facts: [sourceA, sourceB], now: now, sourceHealth: [failedA]
        ).outputThroughput
        #expect(combined.series.count == 1)
        #expect(combined.series.first?.buckets.compactMap(\.absoluteCount).reduce(0, +) == 540)
        #expect(combined.dataState == .stale)
        #expect(combined.coverage == .partial)
        #expect(combined.freshness.isRetained)
        #expect(combined.unavailableReason == .sourceOverloaded)

        var onlyB = MetricFilter()
        onlyB.agents.toggle("claude-code")
        let healthy = TrendBuilder().build(
            facts: [sourceA, sourceB], now: now, filter: onlyB, sourceHealth: [failedA]
        ).outputThroughput
        #expect(healthy.dataState == nil)
        #expect(healthy.coverage == .complete)
        #expect(!healthy.freshness.isRetained)
    }

    @Test func trendStaleMetadataRetainsAgeWithoutMovingOldActivityIntoCurrentBuckets() {
        let sourceA = fact(
            id: "trend-old-a", quality: .measured, observedAt: now.addingTimeInterval(-601), output: 180,
            sourceID: "source-a", agent: .codex
        )
        let sourceB = fact(
            id: "trend-fresh-b", quality: .measured, observedAt: now.addingTimeInterval(-1), output: 360,
            sourceID: "source-b", agent: .claudeCode
        )
        let failedA = SourceHealth(
            sourceID: "source-a", isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE",
            impacts: [.usage], impactedAgents: [.codex], impactedChannels: [.synthetic]
        )

        let chart = TrendBuilder().build(
            facts: [sourceA, sourceB], now: now, sourceHealth: [failedA]
        ).outputThroughput

        let currentCounts = chart.series.flatMap(\.buckets).compactMap(\.absoluteCount)
        let currentTableCounts = chart.table.rows.flatMap(\.cells).filter { $0 != "—" }
        #expect(currentCounts == [360])
        #expect(currentTableCounts == ["360"])
        #expect(chart.sampleCount == 1)
        #expect(chart.dataState == .stale)
        #expect(chart.coverage == .partial)
        #expect(chart.freshness == .observed(at: sourceA.observedAt, now: now, retained: true))

        let staleOnly = TrendBuilder().build(
            facts: [sourceA], now: now, sourceHealth: [failedA]
        ).outputThroughput
        #expect(staleOnly.series.isEmpty)
        #expect(staleOnly.table.rows.flatMap(\.cells).filter { $0 != "—" }.isEmpty)
        #expect(staleOnly.sampleCount == 0)
        #expect(staleOnly.dataState == .stale)
        #expect(staleOnly.coverage == .partial)
        #expect(staleOnly.freshness == .observed(at: sourceA.observedAt, now: now, retained: true))
    }

    @Test func summaryAndPerformancePresentationsExposeCompleteMetricContracts() {
        let old = fact(id: "presentation", quality: .estimated, observedAt: now.addingTimeInterval(-601), output: 600)
        let failed = SourceHealth(
            sourceID: "source-a", isHealthy: false, diagnosticCode: "UNKNOWN_SCHEMA",
            impacts: [.usage], impactedAgents: [.codex], impactedChannels: [.synthetic]
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [old], now: now),
            allFacts: [old],
            now: now,
            sourceHealth: [failed]
        )
        let presentation = LightSnapshotPresentation(snapshot: snapshot)

        #expect(presentation.outputMetadata.qualityText == "Estimated")
        #expect(presentation.outputMetadata.stateText == "Stale")
        #expect(presentation.outputMetadata.coverageText == "Partial")
        #expect(presentation.outputMetadata.freshnessText.contains("Retained"))
        #expect(presentation.outputMetadata.sampleCountText == "n 1")
        #expect(presentation.outputMetadata.definitionVersionText == OutputThroughputDefinition.version)
        #expect(presentation.outputMetadata.sourceAuthorityText == "synthetic")
        #expect(presentation.outputMetadata.scopeText == "All")
        #expect(presentation.outputMetadata.reasonText == UnavailableReasonCode.unsupportedSchema.message)
        #expect(presentation.outputMetadata.actionText == MetricAction.updateSource.message)

        let unavailable = LightSnapshotPresentation(snapshot: SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [], now: now), allFacts: [], now: now
        ))
        #expect(unavailable.dataStateText == "No data")
        #expect(unavailable.outputMetadata.reasonText == UnavailableReasonCode.noObservations.message)
        #expect(unavailable.outputMetadata.actionText == MetricAction.waitForObservations.message)

        let distribution = PerformanceDistribution(
            values: [100], quality: .measured, includesP10: false,
            dataState: .stale, coverage: .partial,
            freshness: .observed(at: now.addingTimeInterval(-10), now: now, retained: true),
            sourceAuthority: "performance-a", scope: .selected,
            definitionVersion: TimeToFirstTokenDefinition.version,
            unavailableReason: .sourceFailure, recommendedAction: .updateSource
        )
        let performance = PerformanceMetricPresentation(kind: .timeToFirstToken, distribution: distribution)
        #expect(performance.secondaryText.contains("n 1"))
        #expect(performance.stateText == "Stale")
        #expect(performance.coverageText == "Partial")
        #expect(performance.freshnessText.contains("Retained"))
        #expect(performance.definitionVersionText == TimeToFirstTokenDefinition.version)
        #expect(performance.sourceAuthorityText == "performance-a")
        #expect(performance.scopeText == "Selected")
        #expect(performance.reasonText == UnavailableReasonCode.sourceFailure.message)
        #expect(performance.actionText == MetricAction.updateSource.message)
    }

    private func fact(
        id: String,
        quality: MeasurementQuality,
        observedAt: Date,
        output: Int,
        sourceID: String = "source-a",
        agent: CodingAgent = .codex
    ) -> UsageFact {
        UsageFact(
            id: id,
            schemaVersion: "synthetic-stable-call-v1",
            sourceID: sourceID,
            codingAgent: agent,
            model: ModelIdentity(raw: "model", display: "Model"),
            sessionID: "session",
            turnID: "turn-\(id)",
            observedAt: observedAt,
            outputTokens: output,
            measurementQuality: quality,
            authority: "synthetic",
            definitionVersion: OutputThroughputDefinition.version,
            tokenParts: TokenParts(
                inputUncached: output,
                cacheRead: 0,
                cacheWrite: 0,
                outputVisible: 0,
                reasoning: 0
            ),
            modelCallID: "call-\(id)",
            sourceChannel: .synthetic,
            measurementGranularity: .modelCall
        )
    }

    private func performanceFact(
        id: String,
        quality: MeasurementQuality,
        observedAt: Date,
        sourceID: String = "performance-a",
        agent: CodingAgent = .codex
    ) -> PerformanceFact {
        PerformanceFact(
            stableRequestID: id,
            sourceID: sourceID,
            codingAgent: agent,
            model: ModelIdentity(raw: "model", display: "Model"),
            observedAt: observedAt,
            durationMilliseconds: 1_000,
            ttftMilliseconds: 100,
            outputTotal: 10,
            isRetry: false,
            sourceChannel: .claudeTelemetry,
            authorityTier: .enhanced,
            measurementGranularity: .modelCall,
            measurementRange: DateInterval(start: observedAt.addingTimeInterval(-1), end: observedAt),
            measurementQuality: quality
        )
    }

    private final class MutableTestClock: Clock, @unchecked Sendable {
        var now: Date
        init(now: Date) { self.now = now }
    }

    private final class FlakyOwnedAdapter: IncrementalSourceAdapter, @unchecked Sendable {
        let ownership: SourceOwnership
        let output: Int
        let failsAfterFirstScan: Bool
        private var scans = 0

        init(ownership: SourceOwnership, output: Int, failsAfterFirstScan: Bool) {
            self.ownership = ownership
            self.output = output
            self.failsAfterFirstScan = failsAfterFirstScan
        }

        var sourceID: String { ownership.sourceID }
        var sourceOwnership: SourceOwnership { ownership }
        var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID):") }
        func rebuiltFileScope(for identity: String) -> SourceFactScope { .idPrefix(identity) }
        func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

        func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
            scans += 1
            if failsAfterFirstScan && scans > 1 { throw RuntimeFixtureError.sourceFailure }
            let agent = ownership.codingAgents.first ?? .codex
            let observation = UsageObservation(
                observationIdentity: "\(sourceID):\(Int(clock.now.timeIntervalSince1970))",
                schemaVersion: "runtime-owned-v1",
                sourceID: sourceID,
                codingAgent: agent,
                model: ModelIdentity(raw: "model", display: "Model"),
                sessionID: "session",
                turnID: "turn",
                observedAt: clock.now,
                outputTokens: output,
                tokenParts: TokenParts(
                    inputUncached: output, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0
                ),
                modelCallID: "call-\(Int(clock.now.timeIntervalSince1970))"
            )
            return SourceScan(
                observations: [observation],
                state: SourceState(sourceID: sourceID, parserVersion: "1"),
                rebuildSource: false,
                health: ownership.health(isHealthy: true)
            )
        }
    }

    private final class LegacyFlakyAdapter: IncrementalSourceAdapter, @unchecked Sendable {
        let sourceID: String
        let agent: CodingAgent
        let output: Int
        let failsAfterFirstScan: Bool
        private var scans = 0

        init(sourceID: String, agent: CodingAgent, output: Int, failsAfterFirstScan: Bool) {
            self.sourceID = sourceID
            self.agent = agent
            self.output = output
            self.failsAfterFirstScan = failsAfterFirstScan
        }

        var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID):") }
        func rebuiltFileScope(for identity: String) -> SourceFactScope { .idPrefix(identity) }
        func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

        func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
            scans += 1
            if failsAfterFirstScan && scans > 1 { throw RuntimeFixtureError.sourceFailure }
            return SourceScan(
                observations: [UsageObservation(
                    observationIdentity: "\(sourceID):\(Int(clock.now.timeIntervalSince1970))",
                    schemaVersion: "legacy-runtime-v1",
                    codingAgent: agent,
                    model: ModelIdentity(raw: "model", display: "Model"),
                    sessionID: "session",
                    turnID: "turn",
                    observedAt: clock.now,
                    outputTokens: output
                )],
                state: SourceState(sourceID: sourceID, parserVersion: "1"),
                rebuildSource: false,
                health: SourceHealth(sourceID: sourceID, isHealthy: true)
            )
        }
    }

    private enum RuntimeFixtureError: Error { case sourceFailure }
}

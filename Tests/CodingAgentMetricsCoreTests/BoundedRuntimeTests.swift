import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

struct BoundedRuntimeTests {
    @Test func newestObservationIsShedOnlyFromTheNoisySource() {
        var queue = SourceObservationQueue(capacityPerSource: 256)

        for index in 0..<257 {
            queue.enqueue(observation(index: index, sourceID: "source-a"))
        }
        queue.enqueue(observation(index: 0, sourceID: "source-b"))

        #expect(queue.count(for: "source-a") == 256)
        #expect(queue.shedCount(for: "source-a") == 1)
        #expect(queue.count(for: "source-b") == 1)
        #expect(queue.shedCount(for: "source-b") == 0)
        let firstDrain = queue.drain(sourceID: "source-a", maximum: 256)
        let secondDrain = queue.drain(sourceID: "source-a", maximum: 256)
        #expect(firstDrain.count == 128)
        #expect(secondDrain.map(\.observationIdentity).last == "source-a-255")
    }

    @Test func snapshotCadenceCoalescesAtOneHertzAndFourHertzOnlyWhileVisible() {
        var scheduler = SnapshotScheduler()
        scheduler.setPopoverVisible(true)

        let firstSecond = [0.0, 0.1, 0.24, 0.25, 0.25, 0.49, 0.5, 0.74, 0.75, 0.99]
            .map { scheduler.tick(at: Date(timeIntervalSince1970: $0)) }
        #expect(firstSecond.filter(\.publishLight).count == 1)
        #expect(firstSecond.filter(\.publishDetail).count == 4)

        scheduler.setPopoverVisible(false)
        let hidden = [1.0, 1.25, 1.5, 1.75]
            .map { scheduler.tick(at: Date(timeIntervalSince1970: $0)) }
        #expect(hidden.filter(\.publishLight).count == 1)
        #expect(hidden.filter(\.publishDetail).isEmpty)
    }

    @Test func hidingAndShowingRestartsDetailWithoutPausingLightHealthTicks() {
        var scheduler = SnapshotScheduler()
        scheduler.setPopoverVisible(true)
        #expect(scheduler.tick(at: Date(timeIntervalSince1970: 0)).publishDetail)

        scheduler.setPopoverVisible(false)
        let hidden = scheduler.tick(at: Date(timeIntervalSince1970: 1))
        #expect(hidden.publishLight)
        #expect(!hidden.publishDetail)

        scheduler.setPopoverVisible(true)
        let shown = scheduler.tick(at: Date(timeIntervalSince1970: 1))
        #expect(!shown.publishLight)
        #expect(shown.publishDetail)
    }

    @Test func detailQueryGateAllowsOnlyOneInFlightQuery() {
        let gate = DetailQueryGate()

        #expect(gate.begin())
        #expect(!gate.begin())
        #expect(gate.inFlightCount == 1)
        gate.end()
        #expect(gate.begin())
        gate.end()
    }

    @Test func factWindowKeepsNewestTwentyThousandChronologicallyAndReportsTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-facts-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteFactStore(url: url)
        try store.upsert((0...20_000).map { fact(index: $0) })

        let window = try store.factWindow(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 20_000)
            ),
            limit: 20_000
        )

        #expect(window.rows.count == 20_000)
        #expect(window.rows.first?.id == "fact-1")
        #expect(window.rows.last?.id == "fact-20000")
        #expect(window.isTruncated)
        #expect(window.retainedRange?.start == Date(timeIntervalSince1970: 1))
        #expect(window.retainedRange?.end == Date(timeIntervalSince1970: 20_000))
    }

    @Test func lightQueryOverloadKeepsNewestLastGoodValueAndMarksPartial() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-light-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let store = try SQLiteFactStore(url: url)
        let facts = (0...20_000).map { index -> UsageFact in
            var value = fact(index: index, sourceID: "source-a")
            value.observedAt = now.addingTimeInterval(-100 + Double(index) / 1_000)
            value.measurementRange = DateInterval(start: value.observedAt, end: value.observedAt)
            return value
        }
        try store.upsert(facts)

        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [], clock: FixedClock(now: now))
        let snapshot = try runtime.lightSnapshotFromStore(filter: .all)

        #expect(snapshot.outputThroughput.selectedOutputTokens == 20_000)
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(snapshot.outputThroughput.unavailableReason == .sourceOverloaded)
        #expect(snapshot.outputThroughput.recommendedAction == .updateSource)
        #expect(snapshot.outputThroughput.dataState != .zero)
        #expect(snapshot.outputThroughput.freshness.lastUpdatedAt == facts.last?.observedAt)
    }

    @Test func queryAllocationRetainsQuietSourceAndMarksOnlyNoisySourcePartial() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-source-allocation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let store = try SQLiteFactStore(url: url)
        let noisy = (0...20_000).map { index -> UsageFact in
            var value = fact(index: index, sourceID: "source-a")
            value.id = "source-a-\(index)"
            value.observedAt = now.addingTimeInterval(-100 + Double(index) / 1_000)
            value.measurementRange = DateInterval(start: value.observedAt, end: value.observedAt)
            return value
        }
        let quiet = (0..<10).map { index -> UsageFact in
            var value = fact(index: index, sourceID: "source-b")
            value.id = "source-b-\(index)"
            value.codingAgent = .claudeCode
            value.observedAt = now.addingTimeInterval(-170 + Double(index))
            value.measurementRange = DateInterval(start: value.observedAt, end: value.observedAt)
            return value
        }
        try store.upsert(noisy + quiet)

        let interval = DateInterval(start: now.addingTimeInterval(-600), end: now)
        let window = try store.factWindow(in: interval, limit: 20_000)
        #expect(window.rows.filter { $0.sourceID == "source-a" }.count == 19_990)
        #expect(window.rows.filter { $0.sourceID == "source-b" }.count == 10)
        #expect(window.truncatedSourceIDs == ["source-a"])

        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [], clock: FixedClock(now: now))
        var quietFilter = MetricFilter()
        quietFilter.agents.toggle("claude-code")
        let quietLight = try runtime.lightSnapshotFromStore(filter: quietFilter)
        #expect(quietLight.outputThroughput.selectedOutputTokens == 10)
        #expect(quietLight.outputThroughput.coverage == .complete)
        #expect(quietLight.outputThroughput.unavailableReason == nil)
        let quietDetail = try runtime.trendSnapshot(filter: quietFilter)
        #expect(quietDetail.outputThroughput.series.flatMap(\.buckets).compactMap(\.absoluteCount).reduce(0, +) == 10)
        #expect(quietDetail.outputThroughput.coverage == .complete)

        var noisyFilter = MetricFilter()
        noisyFilter.agents.toggle("codex")
        let noisyLight = try runtime.lightSnapshotFromStore(filter: noisyFilter)
        #expect(noisyLight.outputThroughput.selectedOutputTokens == 19_990)
        #expect(noisyLight.outputThroughput.coverage == .partial)
        #expect(noisyLight.outputThroughput.unavailableReason == .sourceOverloaded)
    }

    @Test func detailQueryOverloadKeepsNewestWindowAndMarksPartial() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-detail-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let store = try SQLiteFactStore(url: url)
        let facts = (0...20_000).map { index -> UsageFact in
            var value = fact(index: index, sourceID: "source-a")
            value.observedAt = now.addingTimeInterval(-100 + Double(index) / 1_000)
            value.measurementRange = DateInterval(start: value.observedAt, end: value.observedAt)
            return value
        }
        try store.upsert(facts)

        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [], clock: FixedClock(now: now))
        let chart = try runtime.trendSnapshot().outputThroughput

        #expect(chart.series.flatMap(\.buckets).compactMap(\.absoluteCount).reduce(0, +) == 20_000)
        #expect(chart.coverage == .partial)
        #expect(chart.unavailableReason == .sourceOverloaded)
        #expect(chart.recommendedAction == .updateSource)
        #expect(chart.dataState != .zero)
    }

    @Test func everyLiveSeriesIsBoundedToOneHundredEightyPoints() {
        let now = Date(timeIntervalSince1970: 30_000)
        let snapshot = TrendBuilder().build(
            facts: [fact(index: 1)],
            now: now.addingTimeInterval(0.5)
        )

        let modelSeries = [snapshot.outputThroughput, snapshot.tokenBurn, snapshot.calls]
            .flatMap(\.series)
        let partSeries = [snapshot.outputThroughput, snapshot.tokenBurn, snapshot.calls]
            .flatMap(\.partSeries)
        #expect(TrendBuilder.maximumPointsPerSeries == 180)
        #expect(modelSeries.allSatisfy { $0.buckets.count <= TrendBuilder.maximumPointsPerSeries })
        #expect(partSeries.allSatisfy { $0.buckets.count <= TrendBuilder.maximumPointsPerSeries })
    }

    @Test func runtimeDrainsEachSourceIndependentlyAndKeepsOverloadedSourcePartial() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-ingestion-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let sourceA = BurstIncrementalAdapter(sourceID: "source-a", agent: .codex, count: 257)
        let sourceB = BurstIncrementalAdapter(sourceID: "source-b", agent: .claudeCode, count: 1)
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapters: [sourceA, sourceB],
            clock: FixedClock(now: now)
        )

        _ = try runtime.lightSnapshot()
        #expect(try SQLiteFactStore(url: url).allFacts().filter { $0.sourceID == "source-a" }.count == 128)
        #expect(try SQLiteFactStore(url: url).allFacts().filter { $0.sourceID == "source-b" }.count == 1)

        var onlyA = MetricFilter()
        onlyA.agents.toggle("codex")
        let overloaded = try runtime.lightSnapshot(filter: onlyA)
        #expect(overloaded.outputThroughput.selectedOutputTokens == 256)
        #expect(overloaded.outputThroughput.coverage == .partial)
        #expect(overloaded.outputThroughput.unavailableReason == .sourceOverloaded)
        #expect(try SQLiteFactStore(url: url).sourceState(sourceID: "source-a")?.replayState?.acceptedCount == 256)

        var onlyB = MetricFilter()
        onlyB.agents.toggle("claude-code")
        let healthy = try runtime.lightSnapshot(filter: onlyB)
        #expect(healthy.outputThroughput.selectedOutputTokens == 1)
        #expect(healthy.outputThroughput.coverage == .complete)
        #expect(healthy.outputThroughput.unavailableReason == nil)
        #expect(try SQLiteFactStore(url: url).allFacts().filter { $0.sourceID == "source-a" }.count == 257)

        let recovered = try runtime.lightSnapshot(filter: onlyA)
        #expect(recovered.outputThroughput.selectedOutputTokens == 257)
        #expect(recovered.outputThroughput.coverage == .complete)
        #expect(recovered.outputThroughput.unavailableReason == nil)
        #expect(try SQLiteFactStore(url: url).sourceState(sourceID: "source-a") != nil)
    }

    @Test func replayIdentityChangeReappliesRebuildDeletionBeforeAcceptingReplacement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-replay-rewrite-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let adapter = RewritingBurstIncrementalAdapter(sourceID: "rewritten-source")
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: adapter,
            clock: FixedClock(now: now)
        )

        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()

        let facts = try SQLiteFactStore(url: url).allFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.turnID == "replacement-turn")
    }

    @Test func replayPayloadChangeWithStableIdentitiesReappliesDeletionBeforeReplacement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-replay-payload-rewrite-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let adapter = PayloadRewritingBurstIncrementalAdapter(sourceID: "payload-rewritten-source")
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: adapter,
            clock: FixedClock(now: now)
        )

        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()

        let replacementPrefix = try SQLiteFactStore(url: url).allFacts()
        #expect(replacementPrefix.count == 128)
        #expect(replacementPrefix.allSatisfy { $0.outputTokens == 2 })
        #expect(replacementPrefix.allSatisfy { $0.model.raw == "replacement-model" })

        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()
        let completed = try SQLiteFactStore(url: url).allFacts()
        #expect(completed.count == 257)
        #expect(completed.allSatisfy { $0.outputTokens == 2 && $0.model.raw == "replacement-model" })
    }

    @Test func replayDeletionScopeChangeInvalidatesTheAcceptedPrefixCheckpoint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-replay-scope-change-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let adapter = ScopeChangingBurstIncrementalAdapter(sourceID: "scope-changing-source")
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: adapter,
            clock: FixedClock(now: Date(timeIntervalSince1970: 30_000))
        )

        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()

        #expect(try SQLiteFactStore(url: url).allFacts().count == 128)
    }

    @Test func replayCheckpointSurvivesRestartOnlyAfterItsAcceptedPrefixIsPersisted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-replay-restart-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let adapter = StaticReplayBurstIncrementalAdapter(sourceID: "restart-source")
        var runtime: TelemetryRuntime? = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: adapter,
            clock: FixedClock(now: Date(timeIntervalSince1970: 30_000))
        )

        _ = try runtime?.lightSnapshot()
        _ = try runtime?.lightSnapshot()
        let checkpoint = try #require(try SQLiteFactStore(url: url).sourceState(sourceID: "restart-source")?.replayState)
        #expect(checkpoint.acceptedCount == 256)
        #expect(checkpoint.acceptedPrefixDigest?.count == 64)
        #expect(checkpoint.deletionScopesApplied)
        runtime = nil

        let restarted = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: adapter,
            clock: FixedClock(now: Date(timeIntervalSince1970: 30_000))
        )
        _ = try restarted.lightSnapshot()
        #expect(try SQLiteFactStore(url: url).allFacts().count == 257)
        #expect(try SQLiteFactStore(url: url).sourceState(sourceID: "restart-source")?.replayState == nil)
    }

    @Test func legacyReplayWithoutDigestDecodesButFailsClosedAndReappliesDeletion() throws {
        let payload = Data(#"{"sourceID":"legacy-replay-source","parserVersion":"1","replayState":{"acceptedCount":256,"lastAcceptedIdentity":"legacy-replay-source-255","deletionScopesApplied":true}}"#.utf8)
        let legacyState = try JSONDecoder().decode(SourceState.self, from: payload)
        #expect(legacyState.replayState?.acceptedPrefixDigest == nil)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-legacy-replay-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let observations = (0..<257).map { observation(index: $0, sourceID: "legacy-replay-source") }
        let store = try SQLiteFactStore(url: url)
        try store.applyIncremental(
            facts: CanonicalIngestor().ingest(observations),
            deleting: [],
            state: legacyState
        )
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: StaticReplayBurstIncrementalAdapter(sourceID: "legacy-replay-source", outputTokens: 2),
            clock: FixedClock(now: Date(timeIntervalSince1970: 30_000))
        )

        _ = try runtime.lightSnapshot()
        let replacedPrefix = try store.allFacts()
        #expect(replacedPrefix.count == 128)
        #expect(replacedPrefix.allSatisfy { $0.outputTokens == 2 })
    }

    @Test func persistedReplayStaysPartialWhileSourceDisappearsAndCompletesAfterRecovery() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-replay-disappear-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let adapter = DisappearingReplayBurstIncrementalAdapter(sourceID: "disappearing-source")
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapter: adapter,
            clock: FixedClock(now: Date(timeIntervalSince1970: 30_000))
        )

        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()
        #expect(try SQLiteFactStore(url: url).allFacts().count == 256)
        #expect(try SQLiteFactStore(url: url).sourceState(sourceID: adapter.sourceID)?.replayState?.acceptedCount == 256)

        adapter.isAvailable = false
        let disappeared = try runtime.lightSnapshot()
        #expect(disappeared.outputThroughput.selectedOutputTokens != nil)
        #expect(disappeared.outputThroughput.selectedOutputTokens != 0)
        #expect(disappeared.outputThroughput.coverage == .partial)
        #expect(disappeared.outputThroughput.unavailableReason == .sourceOverloaded)
        #expect(try SQLiteFactStore(url: url).allFacts().count == 256)
        #expect(try SQLiteFactStore(url: url).sourceState(sourceID: adapter.sourceID)?.replayState?.acceptedCount == 256)

        adapter.isAvailable = true
        let recovered = try runtime.lightSnapshot()
        #expect(recovered.outputThroughput.selectedOutputTokens == 257)
        #expect(recovered.outputThroughput.coverage == .complete)
        #expect(try SQLiteFactStore(url: url).allFacts().count == 257)
        #expect(try SQLiteFactStore(url: url).sourceState(sourceID: adapter.sourceID)?.replayState == nil)
    }

    @Test func performanceWindowUsesTheFullPrimaryKeyAsAStableLimitBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-performance-tie-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let store = try SQLiteFactStore(url: url)
        let fact: (CodingAgent) -> PerformanceFact = { agent in
            PerformanceFact(
                stableRequestID: "same-request",
                codingAgent: agent,
                model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
                observedAt: now,
                durationMilliseconds: 1_000,
                ttftMilliseconds: 100,
                outputTotal: 91,
                isRetry: false,
                sourceChannel: .synthetic,
                authorityTier: .enhanced,
                measurementGranularity: .modelCall,
                measurementRange: DateInterval(start: now, end: now)
            )
        }
        try store.upsertPerformanceFacts([fact(.codex), fact(.claudeCode)])

        let window = try store.performanceFactWindow(
            in: DateInterval(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1)),
            limit: 1
        )

        #expect(window.isTruncated)
        #expect(window.rows.map(\.codingAgent) == [.codex])
    }

    @Test func performanceQueryIsBoundedAndReportsPartialInsteadOfDroppingNewest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-performance-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let store = try SQLiteFactStore(url: url)
        try store.upsertPerformanceFacts((0...20_000).map { index in
            PerformanceFact(
                stableRequestID: "request-\(index)",
                codingAgent: .claudeCode,
                model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
                observedAt: now.addingTimeInterval(-100 + Double(index) / 1_000),
                durationMilliseconds: 1_000,
                ttftMilliseconds: 100,
                outputTotal: 91,
                isRetry: false,
                sourceChannel: .claudeTelemetry,
                authorityTier: .enhanced,
                measurementGranularity: .modelCall,
                measurementRange: DateInterval(start: now.addingTimeInterval(-100), end: now)
            )
        })

        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [], clock: FixedClock(now: now))
        let performance = try runtime.lightSnapshotFromStore(filter: .all).performance

        #expect(performance.endToEnd.sampleCount == 20_000)
        #expect(performance.endToEnd.coverage == .partial)
        #expect(performance.endToEnd.unavailableReason == .sourceOverloaded)
        #expect(performance.endToEnd.recommendedAction == .updateSource)
        #expect(performance.endToEnd.freshness.lastUpdatedAt == now.addingTimeInterval(-80))
    }

    @Test func performanceAllocationKeepsQuietSourceComplete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-performance-allocation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 30_000)
        let store = try SQLiteFactStore(url: url)
        let makeFact: (Int, String, CodingAgent, Date) -> PerformanceFact = { index, sourceID, agent, date in
            PerformanceFact(
                stableRequestID: "\(sourceID)-request-\(index)",
                sourceID: sourceID,
                codingAgent: agent,
                model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
                observedAt: date,
                durationMilliseconds: 1_000,
                ttftMilliseconds: 100,
                outputTotal: 91,
                isRetry: false,
                sourceChannel: .synthetic,
                authorityTier: .enhanced,
                measurementGranularity: .modelCall,
                measurementRange: DateInterval(start: date, end: date)
            )
        }
        let noisy = (0...20_000).map { index in
            makeFact(index, "source-a", .codex, now.addingTimeInterval(-100 + Double(index) / 1_000))
        }
        let quiet = (0..<10).map { index in
            makeFact(index, "source-b", .claudeCode, now.addingTimeInterval(-500 + Double(index)))
        }
        try store.upsertPerformanceFacts(noisy + quiet)

        let runtime = try TelemetryRuntime(storeURL: url, sourceAdapters: [], clock: FixedClock(now: now))
        var quietFilter = MetricFilter()
        quietFilter.agents.toggle("claude-code")
        let quietPerformance = try runtime.lightSnapshotFromStore(filter: quietFilter).performance
        #expect(quietPerformance.endToEnd.sampleCount == 10)
        #expect(quietPerformance.endToEnd.coverage == .complete)
        #expect(quietPerformance.endToEnd.unavailableReason == nil)

        var noisyFilter = MetricFilter()
        noisyFilter.agents.toggle("codex")
        let noisyPerformance = try runtime.lightSnapshotFromStore(filter: noisyFilter).performance
        #expect(noisyPerformance.endToEnd.sampleCount == 19_990)
        #expect(noisyPerformance.endToEnd.coverage == .partial)
        #expect(noisyPerformance.endToEnd.unavailableReason == .sourceOverloaded)
    }

    @Test func latencyStatisticsUseNearestRankAndNeverRelabelAMiss() {
        let statistics = LatencyStatistics(samplesMilliseconds: [1, 2, 3, 4, 5, 100])

        #expect(statistics.sampleCount == 6)
        #expect(statistics.p50Milliseconds == 3)
        #expect(statistics.p95Milliseconds == 100)
        #expect(statistics.maximumMilliseconds == 100)
        #expect(statistics.outcome(candidateReferenceMilliseconds: 5) == .miss)
        #expect(statistics.outcome(candidateReferenceMilliseconds: 101) == .meet)
    }

    @Test func uiFactQueriesUseRangeIndexesWithoutFullTableScans() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-query-plan-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try SQLiteFactStore(url: url)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        let usage = queryPlan(
            database,
            sql: "SELECT source_id, COUNT(*) FROM usage_facts WHERE observed_at >= 0 AND observed_at <= 1 GROUP BY source_id"
        )
        let retained = queryPlan(
            database,
            sql: "SELECT * FROM usage_facts WHERE source_id = 'synthetic' AND observed_at >= 0 AND observed_at <= 1 ORDER BY observed_at DESC, id DESC LIMIT 129"
        )
        let performance = queryPlan(
            database,
            sql: "SELECT * FROM performance_facts WHERE source_id = 'synthetic' AND observed_at >= 0 AND observed_at <= 1 ORDER BY observed_at DESC, coding_agent_raw DESC, stable_request_id DESC, measurement_granularity DESC LIMIT 20000"
        )

        #expect(usage.contains { $0.contains("usage_facts_observed_at") })
        #expect(retained.contains { $0.contains("usage_facts_source_observed_at") })
        #expect(performance.contains { $0.contains("performance_facts_source_observed_at") })
        #expect(!usage.contains { $0 == "SCAN usage_facts" })
        #expect(!retained.contains { $0 == "SCAN usage_facts" })
        #expect(!performance.contains { $0 == "SCAN performance_facts" })
    }

    @Test func committedPerformanceReportKeepsMissesAndPrivacyBoundaryExplicit() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let report = try String(
            contentsOf: repository.appendingPathComponent("docs/performance/bounded-runtime.md"),
            encoding: .utf8
        )

        #expect(report.components(separatedBy: "**MISS**").count - 1 == 2)
        #expect(report.contains("swift run -c release CodingAgentMetricsApp --benchmark-render 100"))
        #expect(report.contains("Summary popover composition + layout + bitmap render"))
        #expect(report.contains("78.114 ms | 87.294 ms | 95.008 ms"))
        #expect(!report.contains("AppKit/SwiftUI rendering latency was **not measured**"))
        #expect(!report.contains("/Users/"))
        #expect(!report.contains("@"))
        #expect(!report.lowercased().contains("serial number:"))
    }
}

private func observation(index: Int, sourceID: String) -> UsageObservation {
    UsageObservation(
        observationIdentity: "\(sourceID)-\(index)",
        schemaVersion: "synthetic-v1",
        sourceID: sourceID,
        codingAgent: .codex,
        model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
        sessionID: "session",
        turnID: "turn-\(index)",
        observedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        outputTokens: index
    )
}

private func fact(index: Int, sourceID: String = "synthetic-source") -> UsageFact {
    let observedAt = Date(timeIntervalSince1970: TimeInterval(index))
    return UsageFact(
        id: "fact-\(index)",
        schemaVersion: "synthetic-v1",
        sourceID: sourceID,
        codingAgent: .codex,
        model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
        sessionID: "session",
        turnID: "turn-\(index)",
        observedAt: observedAt,
        outputTokens: 1,
        measurementQuality: .measured,
        authority: "synthetic",
        definitionVersion: "synthetic-v1",
        measurementRange: DateInterval(start: observedAt, end: observedAt)
    )
}

private final class BurstIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let sourceID: String
    let agent: CodingAgent
    let count: Int

    init(sourceID: String, agent: CodingAgent, count: Int) {
        self.sourceID = sourceID
        self.agent = agent
        self.count = count
    }

    var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [agent],
            channels: [.synthetic]
        )
    }

    var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID)-") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("\(sourceID)-\(identity)-")
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        let observations = state == nil ? (0..<count).map { index in
            UsageObservation(
                observationIdentity: "\(sourceID)-\(index)",
                schemaVersion: "synthetic-v1",
                sourceID: sourceID,
                codingAgent: agent,
                model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
                sessionID: "session",
                turnID: "turn-\(index)",
                observedAt: clock.now.addingTimeInterval(-1),
                outputTokens: 1
            )
        } : []
        return SourceScan(
            observations: observations,
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: false,
            health: SourceHealth(
                sourceID: sourceID,
                isHealthy: true,
                impacts: [.usage],
                impactedAgents: [agent],
                impactedChannels: [.synthetic]
            )
        )
    }
}

private final class RewritingBurstIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let sourceID: String
    private var scanCount = 0

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.codex],
            channels: [.synthetic]
        )
    }

    var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID)-") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("\(sourceID)-")
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        scanCount += 1
        let observations: [UsageObservation]
        if scanCount == 1 {
            observations = (0..<257).map { index in
                makeObservation(identity: "\(sourceID)-old-\(index)", turnID: "old-turn-\(index)", clock: clock)
            }
        } else {
            observations = [makeObservation(
                identity: "\(sourceID)-replacement",
                turnID: "replacement-turn",
                clock: clock
            )]
        }
        return SourceScan(
            observations: observations,
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: true,
            health: sourceOwnership.health(isHealthy: true)
        )
    }

    private func makeObservation(identity: String, turnID: String, clock: any Clock) -> UsageObservation {
        UsageObservation(
            observationIdentity: identity,
            schemaVersion: "synthetic-v1",
            sourceID: sourceID,
            codingAgent: .codex,
            model: ModelIdentity(raw: "synthetic-model", display: "Synthetic Model"),
            sessionID: "session",
            turnID: turnID,
            observedAt: clock.now.addingTimeInterval(-1),
            outputTokens: 1
        )
    }
}

private final class PayloadRewritingBurstIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let sourceID: String
    private var scanCount = 0

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.codex],
            channels: [.synthetic]
        )
    }

    var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID)-") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("\(sourceID)-")
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        scanCount += 1
        let isReplacement = scanCount > 1
        let observations = (0..<257).map { index in
            UsageObservation(
                observationIdentity: "\(sourceID)-\(index)",
                schemaVersion: "synthetic-v1",
                sourceID: sourceID,
                codingAgent: .codex,
                model: ModelIdentity(
                    raw: isReplacement ? "replacement-model" : "original-model",
                    display: isReplacement ? "Replacement Model" : "Original Model"
                ),
                sessionID: "session",
                turnID: "turn-\(index)",
                observedAt: clock.now.addingTimeInterval(-1),
                outputTokens: isReplacement ? 2 : 1
            )
        }
        return SourceScan(
            observations: observations,
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: true,
            health: sourceOwnership.health(isHealthy: true)
        )
    }
}

private final class ScopeChangingBurstIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let sourceID: String
    private var scanCount = 0

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.codex],
            channels: [.synthetic]
        )
    }

    var sourceRebuildScope: SourceFactScope { .schemaVersion("synthetic-v1") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("\(sourceID)-")
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        scanCount += 1
        return SourceScan(
            observations: (0..<257).map { observation(index: $0, sourceID: sourceID) },
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: scanCount == 1,
            rebuiltFileIdentities: scanCount == 1 ? [] : ["all"],
            health: sourceOwnership.health(isHealthy: true)
        )
    }
}

private final class StaticReplayBurstIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let sourceID: String
    let outputTokens: Int

    init(sourceID: String, outputTokens: Int = 1) {
        self.sourceID = sourceID
        self.outputTokens = outputTokens
    }

    var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.codex],
            channels: [.synthetic]
        )
    }

    var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID)-") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        sourceRebuildScope
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        let observations = (0..<257).map { index -> UsageObservation in
            var value = observation(index: index, sourceID: sourceID)
            value.outputTokens = outputTokens
            return value
        }
        return SourceScan(
            observations: observations,
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: true,
            health: sourceOwnership.health(isHealthy: true)
        )
    }
}

private final class DisappearingReplayBurstIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let sourceID: String
    var isAvailable = true

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.codex],
            channels: [.synthetic]
        )
    }

    var sourceRebuildScope: SourceFactScope { .idPrefix("\(sourceID)-") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        sourceRebuildScope
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] { [] }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        guard isAvailable else {
            return SourceScan(
                observations: [],
                state: SourceState(sourceID: sourceID, parserVersion: "1"),
                rebuildSource: false,
                health: sourceOwnership.health(isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE")
            )
        }
        return SourceScan(
            observations: (0..<257).map { index -> UsageObservation in
                var value = observation(index: index, sourceID: sourceID)
                value.outputTokens = 1
                value.observedAt = clock.now.addingTimeInterval(-1)
                return value
            },
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: true,
            health: sourceOwnership.health(isHealthy: true)
        )
    }
}

private func queryPlan(_ database: OpaquePointer?, sql: String) -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "EXPLAIN QUERY PLAN \(sql)", -1, &statement, nil) == SQLITE_OK,
          let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    var details: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 3) {
        details.append(String(cString: value))
    }
    return details
}

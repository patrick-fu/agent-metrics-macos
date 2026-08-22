import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

struct TrendBuilderTests {
    private let alignedNow = Date(timeIntervalSince1970: 1_771_200)
    private let midBucketNow = Date(timeIntervalSince1970: 1_771_202)

    @Test func completedThroughputBucketsExcludeTheOpenIntervalAndDoNotInventZero() throws {
        let complete = fact(
            id: "complete",
            agent: .codex,
            modelRaw: "gpt-a",
            display: "A",
            observedAt: Date(timeIntervalSince1970: 1_771_197),
            outputTokens: 10
        )
        let atBoundary = fact(
            id: "boundary",
            agent: .codex,
            modelRaw: "gpt-a",
            display: "A",
            observedAt: Date(timeIntervalSince1970: 1_771_200),
            outputTokens: 99
        )
        let openBucket = fact(
            id: "open",
            agent: .codex,
            modelRaw: "gpt-a",
            display: "A",
            observedAt: Date(timeIntervalSince1970: 1_771_201),
            outputTokens: 50
        )
        let chart = TrendBuilder().build(
            facts: [complete, atBoundary, openBucket],
            now: midBucketNow
        ).outputThroughput

        #expect(chart.windowSeconds == OutputThroughputDefinition.windowSeconds)
        #expect(chart.bucketSeconds == 5)
        #expect(chart.series.count == 1)
        let completeBuckets = chart.series[0].buckets.filter(\.isComplete)
        let openBuckets = chart.series[0].buckets.filter { !$0.isComplete }
        #expect(completeBuckets.count == 36)
        #expect(openBuckets.count == 1)
        #expect(openBuckets[0].start == Date(timeIntervalSince1970: 1_771_200))
        #expect(openBuckets[0].end == Date(timeIntervalSince1970: 1_771_205))
        #expect(openBuckets[0].value == nil)
        #expect(openBuckets[0].absoluteCount == nil)

        let lastComplete = try #require(completeBuckets.last)
        #expect(lastComplete.start == Date(timeIntervalSince1970: 1_771_195))
        #expect(lastComplete.end == Date(timeIntervalSince1970: 1_771_200))
        #expect(lastComplete.absoluteCount == 10)
        #expect(lastComplete.value == 2)

        let emptyComplete = completeBuckets.dropLast()
        #expect(emptyComplete.allSatisfy { $0.value == nil && $0.absoluteCount == nil })
        #expect(chart.table.rows.contains { row in
            row.bucketStart == lastComplete.start && row.cells == ["10"]
        })
        #expect(chart.table.rows.contains { row in
            row.bucketStart == openBuckets[0].start && row.cells == ["—"]
        })
    }

    @Test func completedOutputBucketsMatchSelectedWindowsWithoutOverallSeries() {
        let completeFact = fact(
            id: "complete",
            agent: .codex,
            modelRaw: "gpt-a",
            display: "A",
            observedAt: Date(timeIntervalSince1970: 1_771_197),
            outputTokens: 10
        )
        let three = TrendBuilder().build(facts: [completeFact], now: midBucketNow, windowSeconds: 180).outputThroughput
        let five = TrendBuilder().build(facts: [completeFact], now: midBucketNow, windowSeconds: 300).outputThroughput
        let ten = TrendBuilder().build(facts: [completeFact], now: midBucketNow, windowSeconds: 600).outputThroughput
        #expect(three.windowSeconds == 180)
        #expect(five.windowSeconds == 300)
        #expect(ten.windowSeconds == 600)
        #expect(three.series[0].buckets.filter(\.isComplete).count == 36)
        #expect(five.series[0].buckets.filter(\.isComplete).count == 60)
        #expect(ten.series[0].buckets.filter(\.isComplete).count == 120)
        #expect(three.series.count == 1)
        #expect(three.series.contains { $0.identity == .aggregate("overall") } == false)
    }

    @Test func activityUsesBoundedThirtySecondBarsOverTheTenMinuteWindow() {
        let snapshot = TrendBuilder().build(facts: [], now: alignedNow)
        #expect(snapshot.tokenBurn.windowSeconds == TokenBurnDefinition.windowSeconds)
        #expect(snapshot.tokenBurn.bucketSeconds == 30)
        #expect(snapshot.tokenBurn.series.isEmpty)
        #expect(snapshot.calls.windowSeconds == CallsDefinition.windowSeconds)
        #expect(snapshot.calls.bucketSeconds == 30)
        let burnBuckets = TrendBuilder().build(
            facts: [fact(id: "burn", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-1), outputTokens: 0, parts: TokenParts(inputUncached: 1, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0))],
            now: alignedNow
        ).tokenBurn.series[0].buckets
        #expect(burnBuckets.filter(\.isComplete).count == 20)
    }

    @Test func agentAndModelANDDropsCrossProductMatchesFromEveryChart() {
        let facts = [
            fact(id: "codex", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 20),
            fact(id: "claude", agent: .claudeCode, modelRaw: "opus", display: "Opus", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 40, parts: TokenParts(inputUncached: 5, cacheRead: 0, cacheWrite: 0, outputVisible: 40, reasoning: 0), call: "c1"),
        ]
        var filter = MetricFilter()
        filter.agents.toggle("codex")
        filter.models.toggle("opus")
        let snapshot = TrendBuilder().build(facts: facts, now: alignedNow, filter: filter)
        #expect(snapshot.outputThroughput.series.isEmpty)
        #expect(snapshot.tokenBurn.series.isEmpty)
        #expect(snapshot.calls.series.isEmpty)
        #expect(snapshot.outputThroughput.dataState == .absent)
    }

    @Test func seriesKeepRawModelIdentityWhenDisplayNamesCollide() {
        let facts = [
            fact(id: "one", agent: .claudeCode, modelRaw: "opus-4", display: "Opus", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 15),
            fact(id: "two", agent: .claudeCode, modelRaw: "opus-4-thinking", display: "Opus", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 25),
        ]
        let series = TrendBuilder().build(facts: facts, now: alignedNow).outputThroughput.series
        #expect(series.map(\.identity) == [.model("opus-4-thinking"), .model("opus-4")])
        #expect(series.map(\.title) == ["Opus (opus-4-thinking)", "Opus (opus-4)"])
        #expect(series.map(\.colorSlot) == ["opus-4-thinking", "opus-4"])
    }

    @Test func moreThanFiveModelsCollapseToTopFourPlusPerBucketOther() {
        let top = (1...4).map { index in
            fact(
                id: "top-\(index)",
                agent: .codex,
                modelRaw: "top-\(index)",
                display: "Top \(index)",
                observedAt: Date(timeIntervalSince1970: 1_771_167),
                outputTokens: 1_000
            )
        }
        let hiddenEarly = fact(
            id: "hidden-early",
            agent: .codex,
            modelRaw: "hidden-a",
            display: "Hidden A",
            observedAt: Date(timeIntervalSince1970: 1_771_167),
            outputTokens: 10
        )
        let hiddenLateA = fact(
            id: "hidden-late-a",
            agent: .codex,
            modelRaw: "hidden-a",
            display: "Hidden A",
            observedAt: Date(timeIntervalSince1970: 1_771_187),
            outputTokens: 10
        )
        let hiddenLateB = fact(
            id: "hidden-late-b",
            agent: .codex,
            modelRaw: "hidden-b",
            display: "Hidden B",
            observedAt: Date(timeIntervalSince1970: 1_771_187),
            outputTokens: 20
        )
        let chart = TrendBuilder().build(
            facts: top + [hiddenEarly, hiddenLateA, hiddenLateB],
            now: alignedNow
        ).outputThroughput

        #expect(chart.series.map(\.identity) == [.model("top-1"), .model("top-2"), .model("top-3"), .model("top-4"), .other])
        #expect(chart.series.map(\.role) == [.model, .model, .model, .model, .other])
        #expect(chart.series[4].title == "Other")
        #expect(chart.series[4].colorSlot == "other")
        #expect(chart.series[4].emphasis == .other)

        let early = Date(timeIntervalSince1970: 1_771_165)
        let late = Date(timeIntervalSince1970: 1_771_185)
        let other = chart.series[4]
        #expect(other.buckets.first { $0.start == early }?.absoluteCount == 10)
        #expect(other.buckets.first { $0.start == late }?.absoluteCount == 30)
        #expect(other.buckets.filter { $0.start != early && $0.start != late && $0.isComplete }.allSatisfy { $0.absoluteCount == nil })
        #expect(chart.table.columnTitles == ["Top 1", "Top 2", "Top 3", "Top 4", "Other"])
    }

    @Test func fiveOrFewerModelsStayVisibleAndEqualTotalsSortByDisplayThenRaw() {
        let facts = [
            fact(id: "z", agent: .codex, modelRaw: "z-2", display: "Zeta", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 20),
            fact(id: "b", agent: .codex, modelRaw: "a-2", display: "Alpha", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 20),
            fact(id: "a", agent: .codex, modelRaw: "a-1", display: "Alpha", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 20),
            fact(id: "m", agent: .codex, modelRaw: "m-1", display: "Mid", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 40),
            fact(id: "c", agent: .codex, modelRaw: "c-1", display: "Chi", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 10),
        ]
        let chart = TrendBuilder().build(facts: facts, now: alignedNow).outputThroughput
        #expect(chart.series.map(\.identity) == [.model("m-1"), .model("a-1"), .model("a-2"), .model("z-2"), .model("c-1")])
        #expect(chart.series.allSatisfy { $0.role == .model })
        #expect(!chart.series.contains { $0.identity == .other })
    }

    @Test func colorSlotsStayPinnedToIdentityWhenRankingChanges() {
        let low = fact(id: "low", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 5)
        let high = (1...5).map { index in
            fact(id: "high-\(index)", agent: .codex, modelRaw: "top-\(index)", display: "Top \(index)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 50)
        }
        let buried = TrendBuilder().build(facts: high + [low], now: alignedNow).outputThroughput
        #expect(buried.series.map(\.identity).contains(.other))
        #expect(!buried.series.map(\.identity).contains(.model("gpt-a")))

        let risen = fact(id: "risen", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-8), outputTokens: 500)
        let leading = TrendBuilder().build(facts: high + [low, risen], now: alignedNow).outputThroughput
        #expect(leading.series[0].identity == .model("gpt-a"))
        #expect(leading.series[0].colorSlot == "gpt-a")
        #expect(TrendColorPalette.slotIndex("gpt-a") == TrendColorPalette.slotIndex(leading.series[0].colorSlot))
        #expect(leading.series.contains { $0.identity == .other && $0.colorSlot == "other" })
    }

    @Test func presentationUsesTextNotColorForQualityCoverageAndState() {
        let measured = fact(
            id: "measured",
            agent: .codex,
            modelRaw: "gpt-a",
            display: "A",
            observedAt: alignedNow.addingTimeInterval(-10),
            outputTokens: 15
        )
        let derived = TrendPresentation(chart: TrendBuilder().build(facts: [measured], now: alignedNow).outputThroughput)
        #expect(derived.qualityText == "Derived")
        #expect(derived.dataStateText == "-")
        #expect(derived.coverageText == "Complete")
        #expect(derived.allowsContinuousAnimation)

        var estimatedFact = measured
        estimatedFact.id = "estimated"
        estimatedFact.measurementQuality = .estimated
        let estimatedChart = TrendBuilder().build(facts: [estimatedFact], now: alignedNow).outputThroughput
        #expect(estimatedChart.measurementQuality == .estimated)
        #expect(estimatedChart.series[0].emphasis == .estimated)
        #expect(estimatedChart.series[0].colorSlot == "gpt-a")
        let estimated = TrendPresentation(chart: estimatedChart, reduceMotion: true)
        #expect(estimated.qualityText == "Estimated")
        #expect(estimated.allowsContinuousAnimation == false)
        #expect(estimated.seriesCues.map(\.text) == ["Estimated"])
        #expect(estimated.seriesCues.map(\.symbol) == ["┄"])

        var fallback = measured
        fallback.id = "fallback"
        fallback.modelCallID = "request-1"
        fallback.authority = "claude-code-transcript-usage"
        fallback.authorityTier = .fallback
        var unknown = measured
        unknown.id = "unknown"
        unknown.modelCallID = "request-1"
        unknown.authority = "third-party-otel-mirror"
        unknown.authorityTier = .fallback
        let conflicted = TrendBuilder().build(facts: [fallback, unknown], now: alignedNow).tokenBurn
        #expect(conflicted.coverage == .partial)
        #expect(conflicted.sourceAuthority == "mixed")
        #expect(TrendPresentation(chart: conflicted).coverageText == "Partial")
    }

    @Test func presentationGivesBurnPartsNonColorCuesAndHonorsReduceMotion() {
        let parts = TokenParts(inputUncached: 10, cacheRead: 20, cacheWrite: 30, outputVisible: 40, reasoning: 50)
        let chart = TrendBuilder().build(
            facts: [fact(id: "parts", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 40, parts: parts)],
            now: alignedNow
        ).tokenBurn
        let reduced = TrendPresentation(chart: chart, reduceMotion: true)
        #expect(reduced.allowsContinuousAnimation == false)
        #expect(reduced.partCues.map(\.title) == ["Input uncached", "Cache read", "Cache write", "Output visible", "Reasoning"])
        #expect(reduced.partCues.map(\.symbol) == ["■", "▣", "▤", "▲", "●"])
        #expect(reduced.partCues.map(\.textureName) == ["solid", "grid", "stripes", "triangle", "dots"])
        #expect(Set(reduced.partCues.map(\.symbol)).count == 5)
        #expect(TrendPresentation(chart: chart).allowsContinuousAnimation)
        let livePlans = TrendPresentation(chart: chart).partRenderPlans
        #expect(reduced.partRenderPlans == livePlans)
        #expect(livePlans.map(\.textureName) == reduced.partCues.map(\.textureName))
        #expect(livePlans.map(\.pattern) == ["solid", "grid", "stripes", "triangle", "dots"])
    }

    @Test func fourNormalSeriesGetDistinctStableNonColorCues() {
        let facts = (1...4).map { value in
            fact(id: "m\(value)", agent: .codex, modelRaw: "model-\(value)", display: "Model \(value)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: value * 10)
        }
        let chart = TrendBuilder().build(facts: facts, now: alignedNow).outputThroughput
        #expect(chart.series.allSatisfy { $0.emphasis == .normal })
        let presentation = TrendPresentation(chart: chart)
        #expect(Set(presentation.seriesCues.map(\.endpoint)) == Set(chart.series.map { $0.identity.accessibilityLabel }))
        #expect(presentation.seriesCues.allSatisfy { $0.endpoint == $0.identityLabel })

        let reversed = TrendPresentation(chart: TrendBuilder().build(facts: facts.reversed(), now: alignedNow).outputThroughput)
        let first = Dictionary(uniqueKeysWithValues: presentation.seriesCues.map { ($0.identityLabel, "\($0.symbol)|\($0.dash)|\($0.endpoint)") })
        let second = Dictionary(uniqueKeysWithValues: reversed.seriesCues.map { ($0.identityLabel, "\($0.symbol)|\($0.dash)|\($0.endpoint)") })
        #expect(first == second)
    }

    @Test func identityCueIgnoresColorSlotCollisionAndTopFourMembership() {
        let pair = collidingRawIdentities()
        let left = TrendNonColorCuePalette.cue(forRawIdentity: pair.0)
        let right = TrendNonColorCuePalette.cue(forRawIdentity: pair.1)
        #expect(TrendColorPalette.slotIndex(pair.0) == TrendColorPalette.slotIndex(pair.1))
        #expect(left.endpoint == pair.0)
        #expect(right.endpoint == pair.1)
        #expect(left.endpoint != right.endpoint)
        #expect(left == TrendNonColorCuePalette.cue(forRawIdentity: pair.0))

        let leader = fact(id: "lead", agent: .codex, modelRaw: pair.0, display: "Lead", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 500)
        let stable = (1...3).map { value in
            fact(id: "keep-\(value)", agent: .codex, modelRaw: "keep-\(value)", display: "Keep \(value)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 80)
        }
        let four = TrendPresentation(chart: TrendBuilder().build(facts: [leader] + stable, now: alignedNow).outputThroughput)
        let extras = (1...3).map { value in
            fact(id: "extra-\(value)", agent: .codex, modelRaw: "extra-\(value)", display: "Extra \(value)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 40)
        }
        let six = TrendPresentation(chart: TrendBuilder().build(facts: [leader] + stable + extras, now: alignedNow).outputThroughput)
        let before = four.seriesCues.first { $0.identityLabel == pair.0 }
        let after = six.seriesCues.first { $0.identityLabel == pair.0 }
        #expect(before?.symbol == after?.symbol)
        #expect(before?.dash == after?.dash)
        #expect(before?.endpoint == pair.0)
        #expect(after?.endpoint == pair.0)
        #expect(Set(six.seriesCues.map(\.endpoint)).count == six.seriesCues.count)
    }

    @Test func burnBarsKeepMutuallyExclusivePartsAndTheNormalizedTotal() throws {
        let parts = TokenParts(inputUncached: 10, cacheRead: 20, cacheWrite: 30, outputVisible: 40, reasoning: 0)
        let chart = TrendBuilder().build(
            facts: [fact(
                id: "parts",
                agent: .codex,
                modelRaw: "gpt-a",
                display: "A",
                observedAt: alignedNow.addingTimeInterval(-15),
                outputTokens: 40,
                parts: parts
            )],
            now: alignedNow
        ).tokenBurn
        let bucket = try #require(chart.series[0].buckets.last { $0.absoluteCount != nil })
        #expect(bucket.absoluteCount == 100)
        #expect(bucket.parts == parts)
        #expect(bucket.value == 200)
        #expect(chart.table.rows.contains { $0.bucketStart == bucket.start && $0.cells == ["10", "20", "30", "40", "0"] })
    }

    @Test func callBarsCountStableIdentitiesOnceAndIgnoreMissingIDs() throws {
        let supported = [
            fact(id: "one", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-12), outputTokens: 1, call: "call-1"),
            fact(id: "dup", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-11), outputTokens: 1, call: "call-1"),
            fact(id: "two", agent: .codex, modelRaw: "gpt-a", display: "A", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 1, call: "call-2"),
        ]
        let unsupported = fact(id: "missing", agent: .claudeCode, modelRaw: "opus", display: "Opus", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 1, call: nil)
        let chart = TrendBuilder().build(facts: supported + [unsupported], now: alignedNow).calls
        #expect(chart.series.map(\.identity) == [.aggregate("calls")])
        let counted = try #require(chart.series[0].buckets.last { $0.absoluteCount != nil })
        #expect(counted.absoluteCount == 2)
        #expect(counted.value == 4)
        #expect(chart.measurementQuality == .derived)
    }

    @Test func snapshotKPIAndTrendChartsShareAuthorityCoalescing() {
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var fallback = fact(
            id: "fallback",
            agent: .claudeCode,
            modelRaw: "claude-a",
            display: "Claude",
            observedAt: alignedNow.addingTimeInterval(-20),
            outputTokens: 100,
            parts: parts,
            call: "request-1"
        )
        fallback.authority = "claude-code-transcript-usage"
        fallback.authorityTier = .fallback
        var enhanced = fact(
            id: "enhanced",
            agent: .claudeCode,
            modelRaw: "claude-a",
            display: "Claude",
            observedAt: alignedNow.addingTimeInterval(-20),
            outputTokens: 100,
            parts: parts,
            call: "request-1"
        )
        enhanced.authority = "claude-otel-request"
        enhanced.authorityTier = .enhanced
        let facts = [fallback, enhanced]
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, now: alignedNow),
            allFacts: facts,
            now: alignedNow
        )
        let selected = AuthorityCoalescing.select(facts)
        #expect(selected.facts.map(\.id) == ["enhanced"])
        #expect(snapshot.tokenBurn.selectedBurnTokens == 100)
        #expect(snapshot.tokenBurn.sourceAuthority == "claude-otel-request")
        #expect(snapshot.outputThroughput.selectedOutputTokens == 100)
        let trends = TrendBuilder().build(facts: facts, now: alignedNow)
        #expect(trends.tokenBurn.sourceAuthority == "claude-otel-request")
        #expect(trends.tokenBurn.series[0].buckets.compactMap(\.absoluteCount).reduce(0, +) == 100)
        #expect(trends.outputThroughput.series[0].buckets.compactMap(\.absoluteCount).reduce(0, +) == 100)
        #expect(trends.outputThroughput.series.count == 1)
    }

    @Test func sqliteRangeQueryUsesObservedAtIndexAndStaysBounded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trend-range-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteFactStore(url: url)
        let old = fact(id: "old", agent: .codex, modelRaw: "old-model", display: "Old", observedAt: alignedNow.addingTimeInterval(-1_000), outputTokens: 9)
        let recent = fact(id: "recent", agent: .codex, modelRaw: "new-model", display: "New", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 4)
        let future = fact(id: "future", agent: .codex, modelRaw: "future-model", display: "Future", observedAt: alignedNow.addingTimeInterval(10), outputTokens: 8)
        try store.upsert([old, recent, future])

        let loaded = try store.facts(in: DateInterval(start: alignedNow.addingTimeInterval(-600), end: alignedNow))
        #expect(loaded.map(\.id) == ["recent"])

        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA index_list(usage_facts);", -1, &statement, nil) == SQLITE_OK)
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 1) {
                names.append(String(cString: pointer))
            }
        }
        sqlite3_finalize(statement)
        #expect(names.contains("usage_facts_observed_at"))

        statement = nil
        #expect(sqlite3_prepare_v2(database, "PRAGMA index_info(usage_facts_observed_at);", -1, &statement, nil) == SQLITE_OK)
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 2) {
                columns.append(String(cString: pointer))
            }
        }
        sqlite3_finalize(statement)
        #expect(columns == ["observed_at"])
    }

    @Test func runtimeTrendRefreshReadsTheActivityWindowInsteadOfTheWholeStore() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("trend-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let clock = FixedClock(now: alignedNow)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: FixedTrendSourceAdapter(observations: [
                observation(id: "old", agent: .codex, modelRaw: "old-model", display: "Old", observedAt: alignedNow.addingTimeInterval(-1_200), outputTokens: 90),
                observation(id: "recent", agent: .codex, modelRaw: "new-model", display: "New", observedAt: alignedNow.addingTimeInterval(-12), outputTokens: 18),
            ]),
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.modelIdentities.map(\.raw) == ["new-model"])
        let trends = try runtime.trendSnapshot()
        #expect(trends.outputThroughput.series.map(\.identity) == [.model("new-model")])
        #expect(snapshot.outputThroughput.selectedOutputTokens == 18)
    }

    @Test func duplicateDisplayNamesUseRawIdentityAndTotalsBeforeTieBreaks() {
        let facts = [
            fact(id: "low", agent: .codex, modelRaw: "opus-a", display: "Opus", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 10),
            fact(id: "high", agent: .codex, modelRaw: "opus-b", display: "Opus", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 20),
        ]
        let chart = TrendBuilder().build(facts: facts, now: alignedNow).outputThroughput
        #expect(chart.series.map(\.identity) == [.model("opus-b"), .model("opus-a")])
        #expect(chart.table.columnTitles == ["Opus (opus-b)", "Opus (opus-a)"])
        #expect(chart.table.columns.map(\.identityLabel) == ["opus-b", "opus-a"])
        #expect(chart.table.qualityText == "Derived")
        #expect(chart.table.coverageText == "Complete")
        #expect(chart.table.dataStateText == "-")
    }

    @Test func accessibleTableKeepsTopFourOtherAndExactAbsoluteValues() throws {
        let facts = (1...6).map { value in
            fact(id: "m\(value)", agent: .codex, modelRaw: "m\(value)", display: "Top \(value)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: (7 - value) * 10)
        }
        let chart = TrendBuilder().build(facts: facts, now: alignedNow).outputThroughput
        #expect(chart.table.columnTitles == ["Top 1", "Top 2", "Top 3", "Top 4", "Other"])
        #expect(chart.table.columns.map(\.identityLabel) == ["m1", "m2", "m3", "m4", "Other models"])
        #expect(chart.table.rows.contains { $0.cells == ["60", "50", "40", "30", "30"] })
        #expect(chart.table.columns.map(\.emphasisText) == ["Exact", "Exact", "Exact", "Exact", "Other"])

        let valuedRow = try #require(chart.table.rows.firstIndex { $0.cells == ["60", "50", "40", "30", "30"] })
        var cursor = AccessibleTrendTableCursor(rowIndex: valuedRow)
        #expect(cursor.announcement(in: chart.table).contains("Top 1"))
        #expect(cursor.announcement(in: chart.table).contains("m1"))
        #expect(cursor.announcement(in: chart.table).contains("60"))
        cursor.move(rows: 0, columns: 4, in: chart.table)
        #expect(cursor.announcement(in: chart.table).contains("Other"))
        #expect(cursor.announcement(in: chart.table).contains("Other models"))
        #expect(cursor.announcement(in: chart.table).contains("30"))
        cursor.move(rows: 0, columns: 1, in: chart.table)
        #expect(cursor.columnIndex == 4)
    }

    @Test func topFourRankingUsesOnlyCompletedBucketsAndTotalsBeforeNames() {
        let closed = (1...6).map { value in
            fact(id: "closed-\(value)", agent: .codex, modelRaw: "m\(value)", display: "Model \(value)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: value * 10)
        }
        let open = fact(id: "open", agent: .codex, modelRaw: "open-winner", display: "A", observedAt: alignedNow.addingTimeInterval(1), outputTokens: 9_999)
        let chart = TrendBuilder().build(facts: closed + [open], now: alignedNow.addingTimeInterval(2)).outputThroughput
        #expect(chart.series.map(\.identity) == [.model("m6"), .model("m5"), .model("m4"), .model("m3"), .other])
        #expect(chart.series.last?.buckets.last?.isComplete == false)
        #expect(chart.series.last?.buckets.last?.absoluteCount == nil)
    }

    @Test func reservedOtherCannotCollideWithARawModelIdentity() {
        let facts = (1...6).map { value in
            fact(id: "m\(value)", agent: .codex, modelRaw: value == 6 ? "other" : "m\(value)", display: "M \(value)", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: value)
        }
        let identities = TrendBuilder().build(facts: facts, now: alignedNow).outputThroughput.series.map(\.identity)
        #expect(identities.contains(.model("other")))
        #expect(identities.contains(.other))
    }

    @Test func burnPartStacksPreserveCanonicalAbsoluteSums() {
        let parts = TokenParts(inputUncached: 10, cacheRead: 20, cacheWrite: 30, outputVisible: 40, reasoning: 50)
        let chart = TrendBuilder().build(facts: [fact(id: "parts", agent: .codex, modelRaw: "m", display: "M", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 40, parts: parts)], now: alignedNow).tokenBurn
        let partCounts = chart.partSeries.compactMap { $0.buckets.last(where: { $0.absoluteCount != nil })?.absoluteCount }
        #expect(chart.partSeries.map(\.part) == [.inputUncached, .cacheRead, .cacheWrite, .outputVisible, .reasoning])
        #expect(partCounts.reduce(0, +) == 150)
        #expect(chart.table.columnTitles == ["Input uncached", "Cache read", "Cache write", "Output visible", "Reasoning"])
        #expect(chart.table.columns.map(\.identityLabel) == ["Input uncached", "Cache read", "Cache write", "Output visible", "Reasoning"])
        #expect(chart.table.columns.map(\.symbol) == ["■", "▣", "▤", "▲", "●"])
        #expect(Set(chart.table.columns.map(\.symbol)).count == 5)
        #expect(chart.table.rows.contains { $0.cells == ["10", "20", "30", "40", "50"] })
    }

    @Test func callsConflictKeepsOneStableCallAndMatchesKPIConflictSemantics() {
        var first = fact(id: "a", agent: .claudeCode, modelRaw: "m", display: "M", observedAt: alignedNow.addingTimeInterval(-10), outputTokens: 1, call: "request")
        first.authority = "one"
        var second = first
        second.id = "b"
        second.authority = "two"
        let snapshot = SnapshotBuilder().buildLightSnapshot(sample: LiveSampler().sample(facts: [first, second], now: alignedNow), allFacts: [first, second], now: alignedNow)
        let chart = TrendBuilder().build(facts: [first, second], now: alignedNow).calls
        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.calls.coverage == .partial)
        #expect(snapshot.calls.sourceAuthority == "mixed")
        #expect(chart.series[0].buckets.compactMap(\.absoluteCount).reduce(0, +) == 1)
        #expect(chart.coverage == .partial)
        #expect(chart.sourceAuthority == "mixed")
    }

    @Test func lightSnapshotDoesNotCarryTrendsAndRuntimeBuildsDetailsOnDemand() throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("trend-detail-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let runtime = try TelemetryRuntime(storeURL: storeURL, sourceAdapter: FixedTrendSourceAdapter(observations: [observation(id: "oldest", agent: .codex, modelRaw: "m", display: "M", observedAt: midBucketNow.addingTimeInterval(-602), outputTokens: 7, parts: TokenParts(inputUncached: 7, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0))]), clock: FixedClock(now: midBucketNow))
        let light = try runtime.lightSnapshot()
        #expect(Mirror(reflecting: light).children.contains { $0.label == "trends" } == false)
        let detail = try runtime.trendSnapshot()
        let series = try #require(detail.tokenBurn.series.first)
        #expect(series.buckets.first?.absoluteCount == 7)
    }
}

private func fact(
    id: String,
    agent: CodingAgent,
    modelRaw: String,
    display: String,
    observedAt: Date,
    outputTokens: Int,
    parts: TokenParts? = nil,
    call: String? = nil
) -> UsageFact {
    UsageFact(
        id: id,
        schemaVersion: "synthetic-trend-v1",
        codingAgent: agent,
        model: ModelIdentity(raw: modelRaw, display: display),
        sessionID: "session",
        turnID: "turn",
        observedAt: observedAt,
        outputTokens: outputTokens,
        measurementQuality: .measured,
        authority: "synthetic-trend",
        definitionVersion: OutputThroughputDefinition.version,
        tokenParts: parts,
        modelCallID: call,
        measurementRange: DateInterval(start: observedAt.addingTimeInterval(-1), end: observedAt)
    )
}

private func observation(
    id: String,
    agent: CodingAgent,
    modelRaw: String,
    display: String,
    observedAt: Date,
    outputTokens: Int,
    parts: TokenParts? = nil
) -> UsageObservation {
    UsageObservation(
        observationIdentity: id,
        schemaVersion: "synthetic-trend-v1",
        codingAgent: agent,
        model: ModelIdentity(raw: modelRaw, display: display),
        sessionID: "session",
        turnID: "turn",
        observedAt: observedAt,
        outputTokens: outputTokens,
        tokenParts: parts
    )
}

private struct FixedTrendSourceAdapter: SourceAdapter {
    let observations: [UsageObservation]
    func loadObservations(clock: any Clock) throws -> [UsageObservation] { observations }
}

private func collidingRawIdentities() -> (String, String) {
    var seen: [Int: String] = [:]
    for value in 0..<10_000 {
        let identity = "slot-\(value)"
        let slot = TrendColorPalette.slotIndex(identity)
        if let existing = seen[slot], existing != identity {
            return (existing, identity)
        }
        seen[slot] = identity
    }
    fatalError("expected a colorSlot collision")
}

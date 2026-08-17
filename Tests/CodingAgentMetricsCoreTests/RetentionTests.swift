import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

struct RetentionTests {
    @Test func capacityUsesTheFirstByteOrFactThresholdReached() {
        let policy = RetentionPolicy()

        #expect(policy.level(for: StoreCapacity(bytes: 749 * 1_024 * 1_024, factCount: 1_499_999)) == .normal)
        #expect(policy.level(for: StoreCapacity(bytes: 750 * 1_024 * 1_024, factCount: 1)) == .warning)
        #expect(policy.level(for: StoreCapacity(bytes: 1, factCount: 1_500_000)) == .warning)
        #expect(policy.level(for: StoreCapacity(bytes: 1_024 * 1_024 * 1_024, factCount: 1)) == .hardLimit)
        #expect(policy.level(for: StoreCapacity(bytes: 1, factCount: 2_000_000)) == .hardLimit)
    }

    @Test func storeCapacityCountsSQLiteSidecarsAndEveryLogicalFact() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert([usageFact(id: "usage", at: now)])
        try store.upsertPerformanceFacts([PerformanceFact(
            stableRequestID: "request",
            codingAgent: .claudeCode,
            model: ModelIdentity(raw: "model", display: "Model"),
            observedAt: now,
            durationMilliseconds: 1_000,
            ttftMilliseconds: 100,
            outputTotal: 10,
            isRetry: false,
            sourceChannel: .claudeTelemetry,
            authorityTier: .enhanced,
            measurementGranularity: .modelCall,
            measurementRange: DateInterval(start: now, end: now)
        )])

        let capacity = try store.capacity()
        let expectedBytes = [url.path, url.path + "-wal", url.path + "-shm"].reduce(Int64(0)) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }

        #expect(capacity.factCount == 2)
        #expect(capacity.bytes == expectedBytes)
        #expect(capacity.bytes > 0)
    }

    @Test func dailyRollupsAreAtomicIdempotentAndLateRawCannotEraseCompactedTotals() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let day = Date(timeIntervalSince1970: 1_900_000_000)
        let cutoff = Date(timeIntervalSince1970: 1_900_100_000)
        try store.upsert([
            usageFact(id: "old-a", at: day),
            usageFact(id: "old-b", at: day.addingTimeInterval(60)),
        ])

        #expect(try store.compactDailyRollups(olderThan: cutoff) == 2)
        let first = try store.dailyRollups()
        #expect(first.count == 1)
        #expect(first[0].outputTokens == 20)
        #expect(first[0].sampleCount == 2)
        #expect(first[0].measurementQuality == .derived)
        #expect(first[0].coverage == .complete)
        #expect(first[0].sourceID == "source")
        #expect(first[0].definitionVersion == "synthetic-v1")
        #expect(try store.allFacts().isEmpty)

        #expect(try store.compactDailyRollups(olderThan: cutoff) == 0)
        #expect(try store.dailyRollups() == first)

        try store.upsert([usageFact(id: "late-rebuild", at: day.addingTimeInterval(120))])
        #expect(try store.compactDailyRollups(olderThan: cutoff) == 0)
        let conflicted = try store.dailyRollups()
        #expect(conflicted.count == 1)
        #expect(conflicted[0].outputTokens == 20)
        #expect(conflicted[0].sampleCount == 2)
        #expect(conflicted[0].coverage == .partial)
        #expect(try store.allFacts().map(\.id) == ["late-rebuild"])
    }

    @Test func prunedRollupBucketCannotLaterConsumePartialLateRawAsComplete() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let day = Date(timeIntervalSince1970: 1_900_000_000)
        let cutoff = Date(timeIntervalSince1970: 1_900_100_000)
        try store.upsert([
            usageFact(id: "old-a", at: day),
            usageFact(id: "old-b", at: day.addingTimeInterval(60)),
        ])
        _ = try store.compactDailyRollups(olderThan: cutoff)
        try store.upsert([usageFact(id: "late", at: day.addingTimeInterval(120))])
        _ = try store.compactDailyRollups(olderThan: cutoff)
        #expect(try store.dailyRollups().first?.coverage == .partial)
        #expect(try store.deleteOldestDailyRollups(limit: 1) == 1)

        #expect(try store.compactDailyRollups(olderThan: cutoff) == 0)
        #expect(try store.dailyRollups().isEmpty)
        #expect(try store.allFacts().map(\.id) == ["late"])
    }

    @Test func invalidatedRawBackedBucketDeletesThenRebuildsFromAllRawFacts() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let day = Date(timeIntervalSince1970: 1_900_000_000)
        let cutoff = Date(timeIntervalSince1970: 1_900_100_000)
        try store.upsert([
            usageFact(id: "raw-a", at: day),
            usageFact(id: "raw-b", at: day.addingTimeInterval(60)),
        ])

        #expect(try store.rebuildDailyRollups(olderThan: cutoff) == 2)
        #expect(try store.dailyRollups().first?.outputTokens == 20)
        try store.upsert([usageFact(id: "raw-c", at: day.addingTimeInterval(120))])

        #expect(try store.rebuildDailyRollups(olderThan: cutoff) == 3)
        #expect(try store.dailyRollups().first?.outputTokens == 30)
        #expect(try store.dailyRollups().first?.sampleCount == 3)
        #expect(try store.allFacts().count == 3)
    }

    @Test func rollupNeverTurnsUnavailableTokenPartsIntoZero() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let day = Date(timeIntervalSince1970: 1_900_000_000)
        var unavailable = usageFact(id: "unavailable-parts", at: day)
        unavailable.tokenParts = nil
        try store.upsert([unavailable])

        _ = try store.compactDailyRollups(olderThan: day.addingTimeInterval(2 * 24 * 60 * 60))

        #expect(try store.dailyRollups().first?.tokenParts == nil)
    }

    @Test func supersededFactsAreTheFirstSafeEvictionStep() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var fallback = usageFact(id: "fallback", at: now.addingTimeInterval(-100 * 24 * 60 * 60))
        fallback.supersededBy = "enhanced"
        try store.upsert([fallback, usageFact(id: "enhanced", at: now)])

        #expect(try store.deleteSupersededFacts() == 1)
        #expect(try store.allFacts().map(\.id) == ["enhanced"])
        #expect(try store.deleteSupersededFacts() == 0)
    }

    @Test func enhancedAuthorityDurablyMarksMatchingFallbackForFirstStepEviction() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var fallback = usageFact(id: "fallback", at: now)
        fallback.modelCallID = "shared-call"
        var enhanced = usageFact(id: "enhanced", at: now)
        enhanced.modelCallID = "shared-call"
        enhanced.authorityTier = .enhanced
        enhanced.authority = "otlp"
        try store.upsert([fallback])
        try store.upsert([enhanced])

        #expect(try store.allFacts().first(where: { $0.id == "fallback" })?.supersededBy == "enhanced")
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 1,
            hardBytes: Int64.max,
            hardFactCount: 2
        )
        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(result.didPrune)
        #expect(!result.ingestionPaused)
        #expect(try store.allFacts().map(\.id) == ["enhanced"])
    }

    @Test func hardCapPrunesOldestRollupAndPersistsPartialRetentionBoundary() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstDay = now.addingTimeInterval(-120 * 24 * 60 * 60)
        let secondDay = now.addingTimeInterval(-100 * 24 * 60 * 60)
        try store.upsert([
            usageFact(id: "rollup-1", at: firstDay),
            usageFact(id: "rollup-2", at: secondDay),
        ])
        _ = try store.compactDailyRollups(olderThan: now.addingTimeInterval(-90 * 24 * 60 * 60))
        try store.upsert((0..<3).map { index in
            usageFact(id: "protected-\(index)", at: now.addingTimeInterval(-Double(index + 1)))
        })
        let originalRollups = try store.dailyRollups()
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(result.didPrune)
        #expect(!result.ingestionPaused)
        #expect(try store.dailyRollups().map(\.id) == [originalRollups[1].id])
        let metadata = try store.retentionMetadata()
        #expect(metadata.retentionPrunedBefore == originalRollups[0].bucketEnd)
        #expect(metadata.earliestRetainedAt == originalRollups[1].bucketStart)
        #expect(try store.retentionCoverage(in: DateInterval(start: firstDay, end: now)) == .partial)
        #expect(try store.retentionCoverage(in: DateInterval(start: originalRollups[1].bucketStart, end: now)) == .complete)
    }

    @Test func hardCapPrunesOldestSevenToNinetyDayRawBeforeProtectedFacts() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let prunable = now.addingTimeInterval(-30 * 24 * 60 * 60)
        try store.upsert([usageFact(id: "prunable", at: prunable)] + (0..<4).map { index in
            usageFact(id: "protected-\(index)", at: now.addingTimeInterval(-Double(index + 1)))
        })
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(result.didPrune)
        #expect(!result.ingestionPaused)
        #expect(try store.allFacts().map(\.id) == ["protected-3", "protected-2", "protected-1", "protected-0"])
        #expect(try store.retentionMetadata().retentionPrunedBefore == prunable)
        #expect(try store.retentionCoverage(in: DateInterval(start: prunable, end: now)) == .partial)
    }

    @Test func ladderPrunesOldPerformanceRawBeforePausing() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsertPerformanceFacts([performanceFact(id: "old-performance", at: now.addingTimeInterval(-100 * 24 * 60 * 60))])
        try store.upsert((0..<4).map { usageFact(id: "protected-\($0)", at: now.addingTimeInterval(-Double($0 + 1))) })
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(!result.ingestionPaused)
        #expect(try store.allPerformanceFacts().isEmpty)
        #expect(try store.allFacts().count == 4)
    }

    @Test func ladderPrunesLateRawAfterItsOldRollupIsEvicted() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-100 * 24 * 60 * 60)
        _ = try store.upsert([usageFact(id: "original", at: old)])
        _ = try store.compactDailyRollups(olderThan: now.addingTimeInterval(-90 * 24 * 60 * 60))
        try store.upsert([usageFact(id: "late", at: old.addingTimeInterval(60))])
        try store.upsert((0..<4).map { usageFact(id: "protected-\($0)", at: now.addingTimeInterval(-Double($0 + 1))) })
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(!result.ingestionPaused)
        #expect(try store.dailyRollups().isEmpty)
        #expect(try store.allFacts().map(\.id) == ["protected-3", "protected-2", "protected-1", "protected-0"])
    }

    @Test func ladderPrunesRawInThePartialUTCDayBeforeNinetyDayCutoff() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let fullBucketCutoff = floor(cutoff.timeIntervalSince1970 / (24 * 60 * 60)) * (24 * 60 * 60)
        let gap = Date(timeIntervalSince1970: fullBucketCutoff + 1)
        try store.upsert([usageFact(id: "utc-gap", at: gap)] + (0..<4).map {
            usageFact(id: "protected-\($0)", at: now.addingTimeInterval(-Double($0 + 1)))
        })
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(!result.ingestionPaused)
        #expect(try store.allFacts().map(\.id) == ["protected-3", "protected-2", "protected-1", "protected-0"])
    }

    @Test func warningNeverStartsUnscheduledCompactionOrPruning() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert((0..<4).map { index in
            usageFact(id: "old-\(index)", at: now.addingTimeInterval(-100 * 24 * 60 * 60 - Double(index)))
        })
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(result.level == .warning)
        #expect(!result.didPrune)
        #expect(try store.allFacts().count == 4)
        #expect(try store.dailyRollups().isEmpty)
    }

    @Test func normalRetentionTicksDoNotWriteMetadataOrGrowTheWal() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let manager = RetentionManager(store: store)
        let before = try store.capacity()

        for offset in 0..<10 {
            _ = try manager.enforce(at: Date(timeIntervalSince1970: 2_000_000_000 + Double(offset)))
        }

        #expect(try store.capacity().bytes == before.bytes)
        #expect(try store.retentionMetadata() == RetentionMetadata())
    }

    @Test func byteHardCapReclaimsSQLiteAndSidecarsBeforeAdvancingTheLadder() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert((0..<100).map { index in
            usageFact(
                id: "old-byte-heavy-\(index)-\(String(repeating: "x", count: 200))",
                at: now.addingTimeInterval(-100 * 24 * 60 * 60 - Double(index))
            )
        })
        let before = try store.capacity()
        let policy = RetentionPolicy(
            warningBytes: before.bytes - 1,
            warningFactCount: Int.max - 1,
            hardBytes: before.bytes,
            hardFactCount: Int.max
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(!result.ingestionPaused)
        #expect(result.capacityAfter.bytes < before.bytes)
        #expect(try store.dailyRollups().count == 1)
        #expect(try store.allFacts().isEmpty)
    }

    @Test func byteOnlyEnforcementUsesOneReclaimAfterBoundedBulkEviction() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        var reclaimCount = 0
        let store = try SQLiteFactStore(url: url, capacityReclaimProbe: { reclaimCount += 1 })
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert((0..<300).map { index in
            usageFact(
                id: "raw-byte-\(index)-\(String(repeating: "x", count: 200))",
                at: now.addingTimeInterval(-30 * 24 * 60 * 60 - Double(index))
            )
        })
        let before = try store.capacity()
        let policy = RetentionPolicy(
            warningBytes: before.bytes - 1,
            warningFactCount: Int.max - 1,
            hardBytes: before.bytes,
            hardFactCount: Int.max
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(!result.ingestionPaused)
        #expect(reclaimCount == 1)
    }

    @Test func protectedWindowAlonePausesWithExactDiagnosticAndNeverPrunes() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert((0..<5).map { index in
            usageFact(id: "protected-\(index)", at: now.addingTimeInterval(-Double(index + 1)))
        })
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(result.ingestionPaused)
        #expect(result.diagnosticCode == "CAPACITY_PROTECTED_WINDOW")
        #expect(!result.didPrune)
        #expect(try store.allFacts().count == 5)
        #expect(try store.retentionMetadata().diagnosticCode == "CAPACITY_PROTECTED_WINDOW")
    }

    @Test func protectedWindowAloneUsesExactDiagnosticWhenBytesReachFirst() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert((0..<10).map { index in
            usageFact(
                id: "protected-byte-\(index)-\(String(repeating: "x", count: 200))",
                at: now.addingTimeInterval(-Double(index + 1))
            )
        })
        let protectedBytesAfterReclaim = try store.projectedCapacityAfterReclaim().bytes
        let policy = RetentionPolicy(
            warningBytes: protectedBytesAfterReclaim - 1,
            warningFactCount: Int.max - 1,
            hardBytes: protectedBytesAfterReclaim,
            hardFactCount: Int.max
        )

        let result = try RetentionManager(store: store, policy: policy).enforce(at: now)

        #expect(result.ingestionPaused)
        #expect(result.diagnosticCode == "CAPACITY_PROTECTED_WINDOW")
        #expect(try store.allFacts().count == 10)
    }

    @Test func runtimeGateSkipsRefreshAndRejectsEveryIngestionPathWhenProtected() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try SQLiteFactStore(url: url)
        try store.upsert((0..<2).map { index in
            usageFact(id: "protected-\(index)", at: now.addingTimeInterval(-Double(index + 1)))
        })
        let adapter = RefreshProbeAdapter(now: now)
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 1,
            hardBytes: Int64.max,
            hardFactCount: 2
        )
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapters: [adapter],
            clock: FixedClock(now: now),
            retentionPolicy: policy
        )

        let snapshot = try runtime.lightSnapshot()

        #expect(adapter.loadCount == 0)
        #expect(runtime.retentionStatus?.diagnosticCode == "CAPACITY_PROTECTED_WINDOW")
        #expect(snapshot.outputThroughput.coverage == .partial)
        #expect(snapshot.outputThroughput.dataState != .zero)
        #expect(throws: TelemetryRuntimeError.ingestionPaused("CAPACITY_PROTECTED_WINDOW")) {
            try runtime.ingestPerformance([])
        }
        #expect(try store.allFacts().count == 2)
    }

    @Test func refreshThatCrossesWarningPublishesTheWarningInTheSameSnapshot() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = RetentionPolicy(
            warningBytes: Int64.max - 1,
            warningFactCount: 4,
            hardBytes: Int64.max,
            hardFactCount: 5
        )
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapters: [WarningBurstAdapter(now: now)],
            clock: FixedClock(now: now),
            retentionPolicy: policy
        )

        let snapshot = try runtime.lightSnapshot()

        #expect(snapshot.retentionStatus?.level == .warning)
        #expect(snapshot.outputThroughput.coverage == .complete)
        #expect(LightSnapshotPresentation(snapshot: snapshot).capacityText?.contains("Capacity warning") == true)
    }

    @Test func snapshotAndTrendMarkOnlyRangesAffectedByPruningAsPartial() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try SQLiteFactStore(url: url)
        try store.upsert([
            usageFact(id: "pruned", at: now.addingTimeInterval(-120)),
            usageFact(id: "retained", at: now.addingTimeInterval(-60)),
        ])
        _ = try store.deleteOldestRawFacts(
            from: now.addingTimeInterval(-600),
            before: now,
            limit: 1
        )
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapters: [],
            clock: FixedClock(now: now)
        )

        let light = try runtime.lightSnapshotFromStore(filter: .all)
        let trend = try runtime.trendSnapshot()

        #expect(light.outputThroughput.selectedOutputTokens == 10)
        #expect(light.outputThroughput.coverage == .partial)
        #expect(light.outputThroughput.dataState != .zero)
        #expect(light.outputThroughput.unavailableReason == .retentionPruned)
        #expect(trend.outputThroughput.coverage == .partial)
        #expect(trend.outputThroughput.dataState != .zero)
        #expect(trend.outputThroughput.unavailableReason == .retentionPruned)
    }

    @Test func resetAtomicallyClearsAppTelemetryAndPreservesSchemaAndExternalSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-reset-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("facts.sqlite")
        let externalSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-source-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalSource)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source-owned".utf8).write(to: externalSource)
        let store = try SQLiteFactStore(url: url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert([usageFact(id: "usage", at: now)])
        try store.upsertPerformanceFacts([performanceFact(id: "performance", at: now)])
        try store.saveSourceState(SourceState(sourceID: "source", parserVersion: "1", watermarks: ["counter": 10]))
        try createOptionalTelemetryTables(at: url)
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("migration-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try Data("managed export".utf8).write(to: exportDirectory.appendingPathComponent("copy.json"))
        try Data("managed backup".utf8).write(to: backupDirectory.appendingPathComponent("old.sqlite"))

        _ = try store.resetTelemetryData()

        #expect(try store.allFacts().isEmpty)
        #expect(try store.allPerformanceFacts().isEmpty)
        #expect(try store.sourceState(sourceID: "source") == nil)
        #expect(try store.dailyRollups().isEmpty)
        #expect(try store.retentionMetadata() == RetentionMetadata())
        #expect(try optionalTableRowCount(at: url, table: "diagnostics") == 0)
        #expect(try optionalTableRowCount(at: url, table: "runtime_snapshots") == 0)
        #expect(try optionalTableRowCount(at: url, table: "opaque_identities") == 0)
        #expect(try optionalTableRowCount(at: url, table: "schema_metadata") == 1)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: backupDirectory.path))
        #expect(try String(contentsOf: externalSource, encoding: .utf8) == "source-owned")
    }

    @Test func managedArtifactRegistryRejectsRootDatabaseAndExternalPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-boundary-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("facts.sqlite")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-artifact-\(UUID().uuidString)")
        let unmanaged = root.appendingPathComponent("unmanaged.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteFactStore(url: url)

        #expect(throws: StoreError.artifactOutsideAppOwnedRoot(root.path)) {
            try store.registerManagedTelemetryArtifact(root, kind: "root")
        }
        #expect(throws: StoreError.artifactOutsideAppOwnedRoot(url.path)) {
            try store.registerManagedTelemetryArtifact(url, kind: "database")
        }
        #expect(throws: StoreError.artifactOutsideAppOwnedRoot(external.path)) {
            try store.registerManagedTelemetryArtifact(external, kind: "external-user-file")
        }
        #expect(throws: StoreError.artifactOutsideAppOwnedRoot(unmanaged.path)) {
            try store.registerManagedTelemetryArtifact(unmanaged, kind: "unmanaged-app-file")
        }
    }

    @Test func resetStagesFixedManagedRootEntryWithoutFollowingSwappedSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-symlink-root-\(UUID().uuidString)", isDirectory: true)
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-symlink-external-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("facts.sqlite")
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let externalFile = externalRoot.appendingPathComponent("source.jsonl")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("source-owned".utf8).write(to: externalFile)
        let registered = exports.appendingPathComponent("managed.json")
        try Data("managed".utf8).write(to: registered)
        let store = try SQLiteFactStore(
            url: url,
            resetCleanupOperations: ResetCleanupOperations(
                removeItem: { try FileManager.default.removeItem(at: $0) },
                beforeStagingManagedRoots: {
                    try FileManager.default.removeItem(at: exports)
                    try FileManager.default.createSymbolicLink(at: exports, withDestinationURL: externalRoot)
                }
            )
        )
        try store.registerManagedTelemetryArtifact(registered, kind: "export")
        try store.upsert([usageFact(id: "reset", at: Date(timeIntervalSince1970: 2_000_000_000))])

        _ = try store.resetTelemetryData()

        #expect(try store.allFacts().isEmpty)
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "source-owned")
        #expect(!FileManager.default.fileExists(atPath: exports.path))
    }

    @Test func resetFailsClosedForUnclassifiedTablesAndClearsRegisteredOrReservedTelemetry() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SQLiteFactStore(url: url)
        try store.upsert([usageFact(id: "protected-by-classification", at: Date(timeIntervalSince1970: 2_000_000_000))])
        try executeSQL(
            at: url,
            sql: "CREATE TABLE future_unknown (payload TEXT); INSERT INTO future_unknown VALUES ('private');"
        )

        #expect(throws: StoreError.unclassifiedResetTable("future_unknown")) {
            _ = try store.resetTelemetryData()
        }
        #expect(try store.allFacts().map(\.id) == ["protected-by-classification"])
        #expect(try optionalTableRowCount(at: url, table: "future_unknown") == 1)

        try executeSQL(
            at: url,
            sql: "DROP TABLE future_unknown; CREATE TABLE telemetry_future_cache (payload TEXT); INSERT INTO telemetry_future_cache VALUES ('private'); CREATE TABLE future_registered_cache (payload TEXT); INSERT INTO future_registered_cache VALUES ('private'); CREATE TABLE app_preferences (payload TEXT); INSERT INTO app_preferences VALUES ('preserved');"
        )
        try store.registerTelemetryTableForReset("future_registered_cache")

        let result = try store.resetTelemetryData()

        #expect(result.cleanupState == .complete)
        #expect(try optionalTableRowCount(at: url, table: "telemetry_future_cache") == 0)
        #expect(try optionalTableRowCount(at: url, table: "future_registered_cache") == 0)
        #expect(try optionalTableRowCount(at: url, table: "app_preferences") == 1)
    }

    @Test func resetReportsPostCommitCleanupPendingAndRetriesJournalOnNextOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-cleanup-journal-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("facts.sqlite")
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("private export".utf8).write(to: exports.appendingPathComponent("copy.json"))
        var shouldFailRemoval = true
        var store: SQLiteFactStore? = try SQLiteFactStore(
            url: url,
            resetCleanupOperations: ResetCleanupOperations(removeItem: { target in
                if shouldFailRemoval, target.lastPathComponent.hasPrefix(".telemetry-reset-") {
                    shouldFailRemoval = false
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.removeItem(at: target)
            })
        )
        try store?.upsert([usageFact(id: "committed-reset", at: Date(timeIntervalSince1970: 2_000_000_000))])

        let result = try #require(store).resetTelemetryData()

        #expect(result.cleanupState == .pending)
        #expect(try #require(store).allFacts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: exports.path))
        #expect(try optionalTableRowCount(at: url, table: "reset_cleanup_journal") == 1)

        store = nil
        _ = try SQLiteFactStore(url: url)
        #expect(try optionalTableRowCount(at: url, table: "reset_cleanup_journal") == 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".telemetry-reset-") }
        #expect(leftovers.isEmpty)
    }

    @Test func stagingFailureRestoresEveryPreviouslyMovedArtifactBeforeThrowing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-staging-rollback-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("facts.sqlite")
        let first = root.appendingPathComponent("exports/managed-first.json")
        let second = root.appendingPathComponent("migration-backups/managed-second.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let store = try SQLiteFactStore(
            url: url,
            resetCleanupOperations: ResetCleanupOperations(
                removeItem: { try FileManager.default.removeItem(at: $0) },
                beforeManagedRootMove: { index in
                    if index == 1 { throw CocoaError(.fileWriteUnknown) }
                }
            )
        )
        try store.registerManagedTelemetryArtifact(first, kind: "export")
        try store.registerManagedTelemetryArtifact(second, kind: "backup")
        try store.upsert([usageFact(id: "survives-staging-failure", at: Date(timeIntervalSince1970: 2_000_000_000))])

        #expect(throws: (any Error).self) {
            _ = try store.resetTelemetryData()
        }
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(try store.allFacts().map(\.id) == ["survives-staging-failure"])
        #expect(try optionalTableRowCount(at: url, table: "reset_cleanup_journal") == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".telemetry-reset-") })
    }

    @Test func runtimeResetSerializesBehindInflightRefreshAndClearsItsWrite() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let adapter = BlockingResetAdapter(now: now)
        let runtime = try TelemetryRuntime(
            storeURL: url,
            sourceAdapters: [adapter],
            clock: FixedClock(now: now)
        )
        let refreshDone = DispatchSemaphore(value: 0)
        let resetDone = DispatchSemaphore(value: 0)
        let failures = ConcurrentFailures()
        DispatchQueue.global().async {
            do { _ = try runtime.lightSnapshot() } catch { failures.record(error) }
            refreshDone.signal()
        }
        #expect(adapter.started.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            do { _ = try runtime.resetData() } catch { failures.record(error) }
            resetDone.signal()
        }

        adapter.resume.signal()
        #expect(refreshDone.wait(timeout: .now() + 2) == .success)
        #expect(resetDone.wait(timeout: .now() + 2) == .success)
        #expect(failures.isEmpty)
        #expect(try SQLiteFactStore(url: url).allFacts().isEmpty)
        #expect(runtime.sourceHealth.isEmpty)
        #expect(runtime.retentionStatus == nil)
    }
}

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("retention-\(UUID().uuidString).sqlite")
}

private func removeStore(at url: URL) {
    for path in [url.path, url.path + "-wal", url.path + "-shm"] {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func usageFact(id: String, at date: Date, sourceID: String = "source") -> UsageFact {
    UsageFact(
        id: id,
        schemaVersion: "synthetic-v1",
        sourceID: sourceID,
        codingAgent: .codex,
        model: ModelIdentity(raw: "model", display: "Model"),
        sessionID: "session-\(id)",
        turnID: "turn-\(id)",
        observedAt: date,
        outputTokens: 10,
        measurementQuality: .measured,
        authority: "synthetic",
        definitionVersion: "synthetic-v1",
        tokenParts: TokenParts(inputUncached: 1, cacheRead: 2, cacheWrite: 3, outputVisible: 4, reasoning: 0),
        modelCallID: "call-\(id)",
        modelCallCapability: .available,
        sourceChannel: .synthetic,
        authorityTier: .fallback,
        measurementGranularity: .modelCall,
        measurementRange: DateInterval(start: date, end: date)
    )
}

private func performanceFact(id: String, at date: Date) -> PerformanceFact {
    PerformanceFact(
        stableRequestID: id,
        codingAgent: .claudeCode,
        model: ModelIdentity(raw: "model", display: "Model"),
        observedAt: date,
        durationMilliseconds: 1_000,
        ttftMilliseconds: 100,
        outputTotal: 10,
        isRetry: false,
        sourceChannel: .claudeTelemetry,
        authorityTier: .enhanced,
        measurementGranularity: .modelCall,
        measurementRange: DateInterval(start: date, end: date)
    )
}

private func createOptionalTelemetryTables(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    for table in ["diagnostics", "runtime_snapshots", "opaque_identities"] {
        guard sqlite3_exec(database, "CREATE TABLE \(table) (payload TEXT); INSERT INTO \(table) VALUES ('synthetic');", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(table)
        }
    }
}

private func executeSQL(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw StoreError.execFailed(sql)
    }
}

private func optionalTableRowCount(at url: URL, table: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw StoreError.prepareFailed }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
    return Int(sqlite3_column_int64(statement, 0))
}

private final class RefreshProbeAdapter: SourceAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let now: Date

    init(now: Date) {
        self.now = now
    }

    var loadCount: Int {
        lock.withLock { count }
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        lock.withLock { count += 1 }
        return [UsageObservation(
            observationIdentity: "probe",
            schemaVersion: "synthetic-v1",
            sourceID: "probe",
            codingAgent: .codex,
            model: ModelIdentity(raw: "model", display: "Model"),
            sessionID: "session",
            turnID: "turn",
            observedAt: now,
            outputTokens: 1
        )]
    }
}

private final class BlockingResetAdapter: SourceAdapter, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let now: Date

    init(now: Date) {
        self.now = now
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        started.signal()
        _ = resume.wait(timeout: .now() + 2)
        return [UsageObservation(
            observationIdentity: "inflight",
            schemaVersion: "synthetic-v1",
            sourceID: "inflight",
            codingAgent: .codex,
            model: ModelIdentity(raw: "model", display: "Model"),
            sessionID: "session",
            turnID: "turn",
            observedAt: now,
            outputTokens: 1
        )]
    }
}

private struct WarningBurstAdapter: SourceAdapter {
    let now: Date

    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        (0..<4).map { index in
            UsageObservation(
                observationIdentity: "warning-\(index)",
                schemaVersion: "synthetic-v1",
                sourceID: "warning",
                codingAgent: .codex,
                model: ModelIdentity(raw: "model", display: "Model"),
                sessionID: "session",
                turnID: "turn-\(index)",
                observedAt: now.addingTimeInterval(-Double(index + 1)),
                outputTokens: 1
            )
        }
    }
}

private final class ConcurrentFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    func record(_ error: any Error) {
        lock.withLock { failures.append(String(describing: error)) }
    }

    var isEmpty: Bool {
        lock.withLock { failures.isEmpty }
    }
}

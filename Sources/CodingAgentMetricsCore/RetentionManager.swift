import Foundation

public struct RetentionManager: Sendable {
    public static let protectedWindowDiagnostic = "CAPACITY_PROTECTED_WINDOW"
    public static let hardLimitDiagnostic = "CAPACITY_HARD_LIMIT"

    private let store: SQLiteFactStore
    public let policy: RetentionPolicy

    public init(store: SQLiteFactStore, policy: RetentionPolicy = RetentionPolicy()) {
        self.store = store
        self.policy = policy
    }

    public func enforce(at now: Date) throws -> RetentionResult {
        let before = try store.capacity()
        guard policy.level(for: before) == .hardLimit else {
            try store.setRetentionPause(false, diagnosticCode: nil)
            return RetentionResult(
                capacityBefore: before,
                capacityAfter: before,
                didPrune: false,
                ingestionPaused: false,
                diagnosticCode: nil,
                level: policy.level(for: before)
            )
        }

        var didPrune = try store.deleteSupersededFacts() > 0
        var capacity = try store.capacity()
        if didPrune { capacity = try store.projectedCapacityAfterReclaim() }
        if policy.level(for: capacity) == .hardLimit {
            let compacted = try store.compactDailyRollups(
                olderThan: now.addingTimeInterval(-policy.rollupAge)
            )
            didPrune = didPrune || compacted > 0
            capacity = compacted > 0
                ? try store.projectedCapacityAfterReclaim()
                : try store.capacity()
        }
        while policy.level(for: capacity) == .hardLimit {
            let batch = evictionBatch(for: capacity)
            guard try store.deleteOldestDailyRollups(limit: batch) > 0 else { break }
            didPrune = true
            capacity = try store.projectedCapacityAfterReclaim()
        }

        let protectedStart = now.addingTimeInterval(-policy.protectedWindow)
        while policy.level(for: capacity) == .hardLimit {
            let batch = evictionBatch(for: capacity)
            guard try store.deleteOldestRawFacts(
                from: .distantPast,
                before: protectedStart,
                limit: batch
            ) > 0 else { break }
            didPrune = true
            capacity = try store.projectedCapacityAfterReclaim()
        }

        let physicalBeforeReclaim = try store.capacity()
        if physicalBeforeReclaim.bytes >= policy.hardBytes {
            try store.reclaimCapacity()
        }
        capacity = try store.capacity()

        let paused = policy.level(for: capacity) == .hardLimit
        let protectedCount = try store.factCount(since: protectedStart)
        let unprotectedCount = try store.unprotectedFactCount(before: protectedStart)
        let protectedWindowExceedsCountLimit = protectedCount >= policy.hardFactCount
        let protectedWindowExceedsByteLimit = capacity.bytes >= policy.hardBytes
            && protectedCount > 0
            && unprotectedCount == 0
        let diagnostic = paused
            ? (protectedWindowExceedsCountLimit || protectedWindowExceedsByteLimit
                ? Self.protectedWindowDiagnostic
                : Self.hardLimitDiagnostic)
            : nil
        try store.setRetentionPause(paused, diagnosticCode: diagnostic)
        let after = try store.capacity()
        return RetentionResult(
            capacityBefore: before,
            capacityAfter: after,
            didPrune: didPrune,
            ingestionPaused: paused,
            diagnosticCode: diagnostic,
            level: policy.level(for: after)
        )
    }

    private func evictionBatch(for capacity: StoreCapacity) -> Int {
        guard capacity.factCount >= policy.hardFactCount else { return 10_000 }
        let excess = capacity.factCount - policy.hardFactCount + 1
        return min(100_000, max(1, excess))
    }
}

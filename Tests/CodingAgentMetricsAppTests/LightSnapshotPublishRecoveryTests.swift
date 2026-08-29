import Foundation
import Testing
@testable import CodingAgentMetricsApp
@testable import CodingAgentMetricsCore

struct LightSnapshotPublishRecoveryTests {
    @Test @MainActor
    func nilLoadInvokesCompletionAndNextTickStillRuns() async {
        let probe = RecoveryProbe()
        let firstEntered = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let loader = LatestBackgroundLoader<Int, Int>(
            queue: DispatchQueue(label: "loader-nil-recovery"),
            gate: DetailQueryGate(),
            load: { input in
                let count = probe.begin()
                if count == 1 {
                    firstEntered.signal()
                    probe.end()
                    return nil
                }
                secondEntered.signal()
                probe.end()
                return input
            }
        )

        var completions: [Int?] = []
        loader.submit(7) { completions.append($0) }
        #expect(await wait(for: firstEntered, timeout: 1) == .success)
        while completions.count < 1 { await Task.yield() }
        #expect(completions == [nil])

        loader.submit(7) { completions.append($0) }
        #expect(await wait(for: secondEntered, timeout: 1) == .success)
        while completions.count < 2 { await Task.yield() }
        #expect(completions == [nil, 7])
        #expect(probe.loadCount == 2)
    }

    @Test @MainActor
    func failedInFlightSameInputStartsPendingFollowUp() async {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let probe = RecoveryProbe()
        let loader = LatestBackgroundLoader<Int, Int>(
            queue: DispatchQueue(label: "loader-nil-pending"),
            gate: DetailQueryGate(),
            load: { input in
                let count = probe.begin()
                if count == 1 {
                    firstEntered.signal()
                    releaseFirst.wait()
                    probe.end()
                    return nil
                }
                secondEntered.signal()
                probe.end()
                return input
            }
        )

        var completions: [Int?] = []
        loader.submit(7) { completions.append($0) }
        #expect(await wait(for: firstEntered, timeout: 1) == .success)
        loader.submit(7) { completions.append($0) }
        releaseFirst.signal()
        #expect(await wait(for: secondEntered, timeout: 1) == .success)
        while completions.count < 2 { await Task.yield() }
        #expect(completions == [nil, 7])
        #expect(probe.loadCount == 2)
    }

    @Test
    func failedHeroTickKeepsLastSnapshotAndUnblocksDisplay() {
        var decision = LightSnapshotPublishDecision()
        let first = 11
        decision.noteRequested(publishHero: true)
        let success = decision.complete(output: first, publishHero: true, latest: Optional<Int>.none)
        #expect(success.latest == 11)
        #expect(success.hero == 11)

        decision.noteRequested(publishHero: true)
        let failed = decision.complete(output: Optional<Int>.none, publishHero: true, latest: success.latest)
        #expect(failed.latest == 11)
        #expect(failed.hero == 11)

        decision.noteRequested(publishHero: false)
        let recovered = decision.complete(output: 22, publishHero: false, latest: failed.latest)
        #expect(recovered.latest == 22)
        #expect(recovered.hero == nil)
    }
}

private func wait(
    for semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

private final class RecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var loadCount: Int { lock.withLock { count } }

    func begin() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func end() {}
}

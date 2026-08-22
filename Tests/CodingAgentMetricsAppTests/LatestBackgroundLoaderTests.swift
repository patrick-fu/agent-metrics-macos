import Foundation
import Testing
@testable import CodingAgentMetricsApp
@testable import CodingAgentMetricsCore

struct LatestBackgroundLoaderTests {
    @Test @MainActor
    func repeatedCadencePublishesCurrentAndWaitsForTheNextExplicitTick() async {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let probe = LoadProbe()
        let loader = LatestBackgroundLoader<Int, Int>(
            queue: DispatchQueue(label: "loader-cadence-test"),
            gate: DetailQueryGate(),
            load: { input in
                let isFirst = probe.begin()
                if isFirst {
                    firstEntered.signal()
                    releaseFirst.wait()
                } else {
                    secondEntered.signal()
                }
                probe.end()
                return input
            }
        )

        let publications = AsyncStream<String> { continuation in
            loader.submit(7) { _ in continuation.yield("current") }
            #expect(firstEntered.wait(timeout: .now() + 1) == .success)
            loader.submit(7) { _ in continuation.yield("superseded-follow-up") }
            loader.submit(7) { _ in continuation.yield("pending-follow-up") }
            releaseFirst.signal()
        }

        var iterator = publications.makeAsyncIterator()
        #expect(await iterator.next() == "current")
        #expect(await wait(for: secondEntered, timeout: 0.05) == .timedOut)

        loader.submit(7) { _ in }
        #expect(await wait(for: secondEntered, timeout: 1) == .success)
        while probe.snapshot().0 < 2 { await Task.yield() }
        let (finalLoadCount, finalMaximumActiveCount) = probe.snapshot()
        #expect(finalLoadCount == 2)
        #expect(finalMaximumActiveCount == 1)
    }

    @Test @MainActor
    func displayTickDuringInFlightSameInputPublishesHeroWhenLoadFinishes() async {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let loader = LatestBackgroundLoader<Int, Int>(
            queue: DispatchQueue(label: "loader-hero-promotion-test"),
            gate: DetailQueryGate(),
            load: { input in
                firstEntered.signal()
                releaseFirst.wait()
                return input
            }
        )
        var decision = LightSnapshotPublishDecision()
        var published: [Int] = []

        func request(publishHero: Bool) {
            decision.noteRequested(publishHero: publishHero)
            let publishHero = publishHero
            loader.submit(7) { output in
                if decision.shouldPublishHero(forThisCompletion: publishHero) {
                    published.append(output)
                }
            }
        }

        request(publishHero: false)
        #expect(await wait(for: firstEntered, timeout: 1) == .success)
        request(publishHero: true)
        releaseFirst.signal()
        while published.isEmpty { await Task.yield() }
        #expect(published == [7])
    }

    @Test @MainActor
    func submitReturnsImmediatelyAndOnlyTheLatestBlockedRequestPublishes() async {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let loader = LatestBackgroundLoader<Int, Int>(
            queue: DispatchQueue(label: "loader-test"),
            gate: DetailQueryGate(),
            load: { input in
                if input == 1 {
                    firstEntered.signal()
                    releaseFirst.wait()
                }
                return input
            }
        )

        let values = AsyncStream<Int> { continuation in
            loader.submit(1) { continuation.yield($0) }
            #expect(firstEntered.wait(timeout: .now() + 1) == .success)

            loader.submit(2) {
                continuation.yield($0)
                continuation.finish()
            }
            releaseFirst.signal()
        }

        var iterator = values.makeAsyncIterator()
        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == nil)
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

private final class LoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loadCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0

    func begin() -> Bool {
        lock.withLock {
            loadCount += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            return loadCount == 1
        }
    }

    func end() {
        lock.withLock { activeCount -= 1 }
    }

    func snapshot() -> (Int, Int) {
        lock.withLock { (loadCount, maximumActiveCount) }
    }
}

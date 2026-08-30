import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct DetailSnapshotLoadTests {
    @Test
    func beginRequestShowsLoadingUntilMatchingGenerationFinishes() {
        var gate = DetailSnapshotLoadGate()
        #expect(gate.isLoading == false)

        let first = gate.beginRequest()
        #expect(gate.isLoading)
        #expect(first == 1)

        let second = gate.beginRequest()
        #expect(second == 2)
        #expect(gate.finish(generation: first) == false)
        #expect(gate.isLoading)

        let finishedCurrent = gate.finish(generation: second)
        #expect(finishedCurrent)
        #expect(gate.isLoading == false)
        #expect(gate.finish(generation: second) == false)
    }

    @Test
    func invalidateDropsInFlightCompletionsAndClearsLoading() {
        var gate = DetailSnapshotLoadGate()
        let generation = gate.beginRequest()
        gate.invalidate()
        #expect(gate.isLoading == false)
        #expect(gate.finish(generation: generation) == false)
        #expect(gate.isLoading == false)
    }

    @Test
    func trendsAvailabilityPrefersExistingSnapshotOverInFlightRefresh() {
        #expect(DetailSurfaceAvailability.make(inFlight: true, snapshot: nil) == .loading)
        #expect(DetailSurfaceAvailability.make(inFlight: false, snapshot: nil) == .empty)

        let snapshot = TrendBuilder().build(facts: [], now: Date(timeIntervalSince1970: 1_771_200))
        #expect(DetailSurfaceAvailability.make(inFlight: true, snapshot: snapshot) == .content)
        #expect(DetailSurfaceAvailability.make(inFlight: false, snapshot: snapshot) == .content)
    }

    @Test @MainActor
    func runtimeSnapshotsExposeLoadingOnlyWhenNoDetailHasArrived() {
        let snapshots = RuntimeSnapshots(light: nil, detail: nil, isDetailLoading: true)
        #expect(snapshots.showsTrendsLoading)
        #expect(DetailSurfaceAvailability.make(inFlight: snapshots.isDetailLoading, snapshot: snapshots.detail) == .loading)

        snapshots.detail = TrendBuilder().build(facts: [], now: Date(timeIntervalSince1970: 1_771_200))
        #expect(snapshots.showsTrendsLoading == false)
        #expect(DetailSurfaceAvailability.make(inFlight: snapshots.isDetailLoading, snapshot: snapshots.detail) == .content)

        snapshots.detail = nil
        snapshots.isDetailLoading = false
        #expect(snapshots.showsTrendsLoading == false)
        #expect(DetailSurfaceAvailability.make(inFlight: snapshots.isDetailLoading, snapshot: snapshots.detail) == .empty)
    }

    /// The production route is `SummaryPopoverView.body` -> `trendsSurface`.
    /// Exercising that exact builder keeps the loading argument honest without relying on
    /// AppKit's private SwiftUI text-hosting hierarchy.
    @Test @MainActor
    func summaryPopoverRoutesInFlightDetailToTheTrendsSurfaceAsLoading() {
        let snapshots = RuntimeSnapshots(light: nil, detail: nil, isDetailLoading: true)
        let inFlightSurface = summaryPopover(snapshots: snapshots).trendsSurface
        #expect(inFlightSurface.isLoading)
        #expect(inFlightSurface.trends == nil)

        snapshots.isDetailLoading = false
        let settledSurface = summaryPopover(snapshots: snapshots).trendsSurface
        #expect(settledSurface.isLoading == false)
        #expect(settledSurface.trends == nil)
    }

    @Test @MainActor
    func summaryPopoverKeepsExistingDetailAsContentWhileARefreshIsInFlight() {
        let snapshots = RuntimeSnapshots(
            light: nil,
            detail: TrendBuilder().build(facts: [], now: Date(timeIntervalSince1970: 1_771_200)),
            isDetailLoading: true
        )
        let surface = summaryPopover(snapshots: snapshots).trendsSurface
        #expect(surface.isLoading == false)
        #expect(surface.trends != nil)
    }

    @MainActor
    private func summaryPopover(snapshots: RuntimeSnapshots) -> SummaryPopoverView {
        let session = AccessibilitySession()
        session.openPanel()
        session.activate(.viewTrends)
        return SummaryPopoverView(
            snapshot: snapshots.light,
            snapshots: snapshots,
            accessibility: session,
            lifecycleServices: inertLifecycleServices()
        )
    }

}

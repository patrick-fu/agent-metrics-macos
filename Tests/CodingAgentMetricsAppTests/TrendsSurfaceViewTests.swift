import AppKit
import SwiftUI
import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct TrendsSurfaceViewTests {
    @Test @MainActor
    func projectionPreservesIndependentOutputBurnAndCallsDefinitions() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = usageFact(
            id: "measured-call",
            observedAt: now.addingTimeInterval(-10),
            outputTokens: 40,
            modelCallID: "call-1"
        )
        let snapshot = lightSnapshot(facts: [fact], now: now)
        let trends = TrendBuilder().build(facts: [fact], now: now)

        let burn = TrendsSurfaceProjection.make(
            snapshot: snapshot,
            trends: trends,
            activity: .burn,
            isLoading: false
        )
        let calls = TrendsSurfaceProjection.make(
            snapshot: snapshot,
            trends: trends,
            activity: .calls,
            isLoading: false
        )

        #expect(burn.state == .content)
        #expect(burn.output.aggregateText == "0.2 tokens/s")
        #expect(burn.output.windowAndBucketText == "3m window · 5s buckets")
        #expect(burn.activity.title == "Token Burn")
        #expect(burn.activity.aggregateText == "10 tokens/min")
        #expect(burn.activity.aggregateText != "12 tokens/min")
        #expect(burn.activity.windowAndBucketText == "10m window · 30s buckets")
        #expect(burn.output.metadata == "Derived · - · Complete")
        #expect(burn.output.sourceText == "synthetic-codex-token-count · All · output-throughput-v1")
        #expect(calls.activity.title == "Calls")
        #expect(calls.activity.aggregateText == "0.1 calls/min")
        #expect(calls.activity.tableControl == .activityTable)
    }

    @Test @MainActor
    func projectionMakesLoadingEmptyAndSourceUnavailableStatesExplicit() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let empty = TrendsSurfaceProjection.make(
            snapshot: nil,
            trends: nil,
            activity: .burn,
            isLoading: false
        )
        let loading = TrendsSurfaceProjection.make(
            snapshot: nil,
            trends: nil,
            activity: .burn,
            isLoading: true
        )
        let unavailable = TrendsSurfaceProjection.make(
            snapshot: nil,
            trends: TrendBuilder().build(
                facts: [],
                now: now,
                sourceHealth: [SourceHealth(sourceID: "codex", isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE")]
            ),
            activity: .burn,
            isLoading: false
        )

        #expect(empty.state == .empty)
        #expect(empty.message == "Trends unavailable")
        #expect(loading.state == .loading)
        #expect(loading.message == "Loading trends…")
        #expect(unavailable.state == .unavailable)
        #expect(unavailable.message == "The metric source is unavailable.")
    }

    @Test @MainActor
    func viewUsesSafeBackAndExactDataAccessibilitySeams() {
        let view = TrendsSurfaceView(snapshot: nil, trends: nil)

        #expect(TrendsSurfaceView.backAccessibilityLabel == "Back to summary")
        #expect(TrendsSurfaceView.outputTableAccessibilityLabel == "Output Throughput exact data")
        #expect(TrendsSurfaceView.activityTableAccessibilityLabel == "Activity exact data")
        _ = view.body
    }

    @Test @MainActor
    func shortViewportKeepsPinnedHeaderAndScrollsExactDataInsteadOfClipping() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let facts = (0..<24).map { index in
            usageFact(
                id: "trend-scroll-\(index)",
                observedAt: now.addingTimeInterval(-Double(index + 1) * 5),
                outputTokens: 40 + index,
                modelCallID: "call-\(index)"
            )
        }
        let snapshot = lightSnapshot(facts: facts, now: now)
        let trends = TrendBuilder().build(facts: facts, now: now)
        let root = TrendsSurfaceView(snapshot: snapshot, trends: trends)
            .frame(width: AppIdentity.popoverWidth, height: 400, alignment: .top)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: AppIdentity.popoverWidth, height: 400)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let scrollViews = Self.descendants(of: hosting, as: NSScrollView.self)
        #expect(!scrollViews.isEmpty)
        #expect(hosting.bounds.height <= 400 + 1)

        let outerScrolls = scrollViews.filter { scroll in
            let frame = hosting.convert(scroll.bounds, from: scroll)
            return frame.width > 300 && frame.minY > 20
        }
        #expect(!outerScrolls.isEmpty)
        let outer = outerScrolls[0]
        let outerFrame = hosting.convert(outer.bounds, from: outer)
        #expect(outerFrame.minY > 24)

        let contentMaxY = Self.descendants(of: outer, as: NSView.self)
            .map { outer.convert($0.bounds, from: $0).maxY }
            .max() ?? 0
        #expect(contentMaxY > outer.bounds.height + 20)

        let headerChrome = Self.descendants(of: hosting, as: NSView.self).contains { view in
            let frame = hosting.convert(view.bounds, from: view)
            return frame.maxY <= outerFrame.minY + 1
                && frame.minY >= 0
                && (20...40).contains(frame.height)
                && frame.width > 40
                && frame.width < 80
        }
        #expect(headerChrome)
    }

    @MainActor
    private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        if let match = view as? T {
            matches.append(match)
        }
        for child in view.subviews {
            matches.append(contentsOf: descendants(of: child, as: type))
        }
        return matches
    }


    private func lightSnapshot(facts: [UsageFact], now: Date) -> LightSnapshot {
        SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, now: now),
            allFacts: facts,
            now: now
        )
    }

    private func usageFact(id: String, observedAt: Date, outputTokens: Int, modelCallID: String?) -> UsageFact {
        UsageFact(
            id: id,
            schemaVersion: "synthetic-codex-token-count-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: "gpt-synthetic-orion", display: "Synthetic Orion"),
            sessionID: "session-1",
            turnID: "turn-1",
            observedAt: observedAt,
            outputTokens: outputTokens,
            measurementQuality: .measured,
            authority: "synthetic-codex-token-count",
            definitionVersion: OutputThroughputDefinition.version,
            tokenParts: TokenParts(inputUncached: 10, cacheRead: 20, cacheWrite: 30, outputVisible: 40, reasoning: 0),
            modelCallID: modelCallID
        )
    }
}

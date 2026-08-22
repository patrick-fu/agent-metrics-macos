import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct CompactThroughputChartRenderPlanTests {
    @Test func singleBucketSeriesUsesAMarkerInsteadOfAnInvisibleLine() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let chart = TrendBuilder().build(
            facts: [fact(id: "only", raw: "single", display: "Single", tokens: 40, now: now)],
            now: now
        ).outputThroughput

        let plan = CompactThroughputChartRenderPlan.make(chart: chart)
        let series = try! #require(plan.series.first)
        #expect(series.lineSegments.count == 1)
        #expect(series.lineSegments[0].count == 1)
        #expect(series.showsMarker)
        #expect(series.markerShape == TrendLinePlotPlanning.shapeName(for: series.symbol))
    }

    @Test func collidingColorsKeepStableNonColorCuesInLinesAndLegend() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let pair = identitiesWithColorCollisionAndDistinctCue()
        let chart = TrendBuilder().build(
            facts: [
                fact(id: "left", raw: pair.0, display: "Left", tokens: 40, now: now),
                fact(id: "right", raw: pair.1, display: "Right", tokens: 30, now: now),
            ],
            now: now
        ).outputThroughput

        let plan = CompactThroughputChartRenderPlan.make(chart: chart)
        let left = try! #require(plan.series.first { $0.identityLabel == pair.0 })
        let right = try! #require(plan.series.first { $0.identityLabel == pair.1 })
        #expect(left.colorIndex == right.colorIndex)
        #expect(left.symbol != right.symbol || left.dash != right.dash)
        #expect(left.legendLabel == "\(left.symbol) \(left.title)")
        #expect(right.legendLabel == "\(right.symbol) \(right.title)")
    }

    private func fact(id: String, raw: String, display: String, tokens: Int, now: Date) -> UsageFact {
        UsageFact(
            id: id,
            schemaVersion: "synthetic-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: raw, display: display),
            sessionID: "s",
            turnID: "t",
            observedAt: now.addingTimeInterval(-10),
            outputTokens: tokens,
            measurementQuality: .measured,
            authority: "synthetic",
            definitionVersion: OutputThroughputDefinition.version
        )
    }

    private func identitiesWithColorCollisionAndDistinctCue() -> (String, String) {
        var seen: [Int: String] = [:]
        for value in 0..<20_000 {
            let identity = "compact-\(value)"
            let colorSlot = TrendColorPalette.slotIndex(identity, count: 6)
            if let previous = seen[colorSlot] {
                let previousCue = TrendNonColorCuePalette.cue(forRawIdentity: previous)
                let cue = TrendNonColorCuePalette.cue(forRawIdentity: identity)
                if previousCue.symbol != cue.symbol || previousCue.dash != cue.dash {
                    return (previous, identity)
                }
            } else {
                seen[colorSlot] = identity
            }
        }
        fatalError("expected a color collision with distinct non-color cues")
    }
}

import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct TrendLinePlotPlanTests {
    @Test @MainActor func plotPlanUsesCueSymbolShapeAndKeepsRawEndpointLabel() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let pair = collidingRawIdentities()
        let facts = [
            fact(id: "a", raw: pair.0, display: "A", tokens: 40, now: now),
            fact(id: "b", raw: pair.1, display: "B", tokens: 30, now: now),
            fact(id: "c", raw: "keep-c", display: "C", tokens: 20, now: now),
            fact(id: "d", raw: "keep-d", display: "D", tokens: 10, now: now),
        ]
        let chart = TrendBuilder().build(facts: facts, now: now).outputThroughput
        let presentation = TrendPresentation(chart: chart)
        let plans = TrendLinePlotPlanning.plans(chart: chart)

        #expect(plans.count == chart.series.count)
        #expect(TrendChartView.plotPlans(for: chart) == plans)
        _ = TrendChartView(chart: chart, style: .line).body

        for plan in plans {
            #expect(plan.endpointLabel == plan.identityLabel)
            #expect(TrendLinePlotPlanning.knownShapeNames.contains(plan.shapeName))
            #expect(plan.shapeName != plan.endpointLabel)
            #expect(plan.visibleEndpointText.count <= plan.endpointLabel.count)
        }

        for (plan, cue) in zip(plans, presentation.seriesCues) {
            #expect(plan.shapeName == TrendLinePlotPlanning.shapeName(for: cue.symbol))
            #expect(plan.endpointLabel == cue.endpoint)
        }

        let left = plans.first { $0.endpointLabel == pair.0 }
        let right = plans.first { $0.endpointLabel == pair.1 }
        #expect(left != nil)
        #expect(right != nil)
        #expect(left?.endpointLabel != right?.endpointLabel)
        #expect(left?.shapeName != right?.shapeName || left?.endpointLabel != right?.endpointLabel)
        #expect(plans.filter(\.showsEndpointLabel).count <= 5)
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
            authority: "codex-rollout",
            definitionVersion: "v1"
        )
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
}

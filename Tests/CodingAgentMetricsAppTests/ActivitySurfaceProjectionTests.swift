import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct ActivitySurfaceProjectionTests {
    @Test @MainActor
    func selectingCallsUpdatesBindingRenderedChartAndAccessibleTable() {
        let session = AccessibilitySession()
        session.openPanel()
        #expect(session.activityBinding.wrappedValue == .burn)

        session.activityBinding.wrappedValue = .calls
        #expect(session.navigation.activity == .calls)
        #expect(session.activityBinding.wrappedValue == .calls)

        let now = Date(timeIntervalSince1970: 1_771_200)
        let trends = TrendBuilder().build(
            facts: [
                UsageFact(
                    id: "call",
                    schemaVersion: "synthetic-v1",
                    codingAgent: .codex,
                    model: ModelIdentity(raw: "gpt-a", display: "A"),
                    sessionID: "s",
                    turnID: "t",
                    observedAt: now.addingTimeInterval(-10),
                    outputTokens: 40,
                    measurementQuality: .measured,
                    authority: "codex-rollout",
                    definitionVersion: "v1",
                    tokenParts: TokenParts(inputUncached: 10, cacheRead: 20, cacheWrite: 30, outputVisible: 40, reasoning: 0),
                    modelCallID: "call-1"
                )
            ],
            now: now
        )
        session.activate(.viewTrends)
        let surface = ActivitySurfaceProjection.make(navigation: session.navigation, trends: trends)
        #expect(surface.selected == .calls)
        #expect(surface.chartStyle == .calls)
        #expect(surface.table.columnTitles == trends.calls.table.columnTitles)
        #expect(surface.table.columnTitles == ["Calls"])
        #expect(surface.table.columnTitles != trends.tokenBurn.table.columnTitles)
    }
}

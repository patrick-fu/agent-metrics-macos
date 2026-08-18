import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct AccessibilitySurfaceSmokeTests {
    @Test @MainActor
    func summarySettingsAndTrendSurfacesCanBeConstructed() {
        let session = AccessibilitySession()
        session.openPanel()
        let popover = SummaryPopoverView(snapshot: nil, accessibility: session)
        _ = popover.body

        session.activate(.settings)
        _ = popover.body
        #expect(session.surface == .settings)
        #expect(session.focusedControl == .back)

        session.escape()
        session.activate(.viewTrends)
        _ = popover.body
        #expect(session.surface == .trends)

        let chart = TrendBuilder().build(facts: [], now: Date(timeIntervalSince1970: 1_771_200)).tokenBurn
        _ = TrendChartView(chart: chart, style: .burnParts, isTableFocused: true).body
    }
}

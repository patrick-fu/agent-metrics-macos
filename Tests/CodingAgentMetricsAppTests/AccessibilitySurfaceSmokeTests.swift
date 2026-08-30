import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct AccessibilitySurfaceSmokeTests {
    @Test @MainActor
    func summaryRoutesEachSecondarySurfaceWithoutLeavingTheStateMachine() {
        let session = AccessibilitySession()
        session.openPanel()
        let popover = SummaryPopoverView(
            snapshot: nil,
            accessibility: session,
            lifecycleServices: inertLifecycleServices()
        )
        _ = popover.body

        session.activate(.settings)
        _ = popover.body
        #expect(session.surface == .settings)
        #expect(session.focusedControl == .back)

        session.activate(.openDataDiagnostics)
        _ = popover.body
        #expect(session.surface == .dataDiagnostics)
        #expect(session.focusedControl == .back)

        session.escape()
        session.activate(.openAboutUpdates)
        _ = popover.body
        #expect(session.surface == .aboutUpdates)

        session.escape()
        session.escape()
        session.activate(.viewTrends)
        _ = popover.body
        #expect(session.surface == .trends)

        let chart = TrendBuilder().build(facts: [], now: Date(timeIntervalSince1970: 1_771_200)).tokenBurn
        _ = TrendChartView(chart: chart, style: .burnParts, isTableFocused: true).body
    }

    @Test
    func summaryPopoverSourceUsesDedicatedSecondarySurfacesAndResetClearsDiagnostics() throws {
        let source = try Self.sourceContents("Sources/CodingAgentMetricsApp/SummaryPopoverView.swift")
        #expect(source.contains("TrendsSurfaceView("))
        #expect(source.contains("SettingsSurfaceView("))
        #expect(source.contains("DataDiagnosticsSurfaceView("))
        #expect(source.contains("AboutUpdatesSurfaceView("))
        #expect(source.contains("clearEphemeralState()"))
        #expect(source.contains("maxHeight: 720"))
        #expect(source.contains("openDataDiagnostics"))
        #expect(source.contains("openAboutUpdates"))
        #expect(!source.contains("SettingsView("))
    }

    private static func sourceContents(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

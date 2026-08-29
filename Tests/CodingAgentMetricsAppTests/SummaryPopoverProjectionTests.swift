import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct SummaryPopoverProjectionTests {
    @Test @MainActor
    func collapsedSummaryExposesHeroesHidesMetadataAndMergesUnavailablePerformance() {
        let now = Date(timeIntervalSince1970: 1_771_202)
        let first = fact(sessionID: "s1", tokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let second = fact(sessionID: "s2", tokens: 1_800, observedAt: now.addingTimeInterval(-20))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [first, second], now: now),
            allFacts: [first, second],
            now: now
        )
        let trends = TrendBuilder().build(facts: [first, second], now: now)
        let projection = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: trends,
            qualityExpanded: false,
            telemetryEnabled: false
        )

        #expect(projection.title == "Agent Metrics")
        #expect(projection.dataStatus == .live)
        #expect(projection.totalValueText == "20")
        #expect(projection.averageValueText == "10")
        #expect(projection.activeSessionsText == "2 active sessions")
        #expect(projection.agentMenuTitle == "All agents")
        #expect(projection.modelMenuTitle == "All models")
        #expect(projection.performance == .banner)
        #expect(projection.performanceBannerText == "Performance metrics require Enhanced Telemetry")
        #expect(projection.performanceActionText == "Enable")
        #expect(projection.qualityTitle == "Data quality & sources")
        #expect(projection.showsQualityMetadata == false)
        #expect(projection.qualityMetadataLines.isEmpty)
        #expect(projection.detailsTitle == "Details")
        #expect(projection.chartHasOpenBucketGap)
        #expect(!projection.chartSeriesTitles.contains("Overall"))
        #expect(!projection.qualityMetadataLines.contains(where: { $0.contains("output-throughput-v1") }))
    }

    @Test @MainActor
    func expandingQualityRevealsSourceMetadata() {
        let now = Date(timeIntervalSince1970: 1_771_202)
        let sampleFact = fact(sessionID: "s1", tokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [sampleFact], now: now),
            allFacts: [sampleFact],
            now: now
        )
        let collapsed = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: nil,
            qualityExpanded: false,
            telemetryEnabled: false
        )
        let expanded = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: nil,
            qualityExpanded: true,
            telemetryEnabled: false
        )
        #expect(collapsed.showsQualityMetadata == false)
        #expect(expanded.showsQualityMetadata)
        #expect(expanded.qualityMetadataLines.contains(where: { $0.contains("output-throughput-v1") }))
    }

    @Test @MainActor
    func staleHeroHidesLastKnownUntilDetailsExpand() {
        let now = Date(timeIntervalSince1970: 1_771_202)
        let staleFact = fact(sessionID: "s1", tokens: 1_800, observedAt: now.addingTimeInterval(-181))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [staleFact], now: now),
            allFacts: [staleFact],
            now: now
        )
        let collapsed = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: nil,
            qualityExpanded: false,
            telemetryEnabled: false,
            now: now
        )
        #expect(collapsed.totalValueText == "—")
        #expect(collapsed.averageValueText == "—")
        #expect(collapsed.activeSessionsText == "0 active sessions")
        #expect(!collapsed.qualityMetadataLines.contains(where: { $0.contains("Last known") }))

        let expanded = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: nil,
            qualityExpanded: true,
            telemetryEnabled: false,
            now: now
        )
        #expect(expanded.totalValueText == "—")
        #expect(expanded.dataStatus == .stale)
        #expect(expanded.qualityMetadataLines.contains(where: { $0.contains("Last known 10") }))
        #expect(expanded.qualityMetadataLines.contains(where: { $0.contains("Retained") || $0.contains("Stale") }))
    }

    @Test @MainActor
    func projectionUsesPartialAndUnavailableStatusSemantics() {
        let now = Date(timeIntervalSince1970: 1_771_202)
        let liveFact = fact(sessionID: "s1", tokens: 1_800, observedAt: now.addingTimeInterval(-10))
        let partialSnapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [liveFact], now: now),
            allFacts: [liveFact],
            now: now,
            sourceHealth: [SourceHealth(sourceID: "limited-source", isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE")]
        )
        let partial = SummaryPopoverProjection.make(
            snapshot: partialSnapshot,
            trends: nil,
            qualityExpanded: false,
            telemetryEnabled: false,
            now: now
        )
        let unavailable = SummaryPopoverProjection.make(
            snapshot: nil,
            trends: nil,
            qualityExpanded: false,
            telemetryEnabled: false,
            now: now
        )

        #expect(partial.dataStatus == .partial)
        #expect(unavailable.dataStatus == .unavailable)
    }

    @Test @MainActor
    func footerAgeAdvancesWithInjectedNowWithoutRepublishingSnapshot() {
        let generated = Date(timeIntervalSince1970: 1_771_202)
        let liveFact = fact(sessionID: "s1", tokens: 1_800, observedAt: generated.addingTimeInterval(-10))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [liveFact], now: generated),
            allFacts: [liveFact],
            now: generated
        )
        let atGeneration = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: nil,
            qualityExpanded: false,
            telemetryEnabled: false,
            now: generated
        )
        let thirtySecondsLater = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: nil,
            qualityExpanded: false,
            telemetryEnabled: false,
            now: generated.addingTimeInterval(30)
        )
        #expect(atGeneration.footerUpdatedText.contains("Updated 10s ago"))
        #expect(thirtySecondsLater.footerUpdatedText.contains("Updated 40s ago"))
    }

    private func fact(sessionID: String, tokens: Int, observedAt: Date) -> UsageFact {
        UsageFact(
            id: "fact-\(sessionID)-\(tokens)-\(observedAt.timeIntervalSince1970)",
            schemaVersion: "synthetic-codex-token-count-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: "gpt-synthetic-orion", display: "Synthetic Orion"),
            sessionID: sessionID,
            turnID: "turn",
            observedAt: observedAt,
            outputTokens: tokens,
            measurementQuality: .measured,
            authority: "synthetic-codex-token-count",
            definitionVersion: OutputThroughputDefinition.version
        )
    }
}

import CodingAgentMetricsCore
import Foundation

struct SummaryPopoverProjection: Equatable {
    enum DataStatus: Equatable {
        case live
        case partial
        case stale
        case unavailable

        var label: String {
            switch self {
            case .live: "Live"
            case .partial: "Partial"
            case .stale: "Stale"
            case .unavailable: "Unavailable"
            }
        }
    }

    enum PerformancePresentation: Equatable {
        case banner
        case compact
    }

    var title: String
    var windowLabel: String
    var isLive: Bool
    var dataStatus: DataStatus
    var agentMenuTitle: String
    var modelMenuTitle: String
    var totalValueText: String
    var averageValueText: String
    var unitText: String
    var activeSessionsText: String
    var burnValueText: String
    var burnUnitText: String
    var callsValueText: String
    var callsUnitText: String
    var performance: PerformancePresentation
    var performanceBannerText: String?
    var performanceActionText: String?
    var compactTTFT: String?
    var compactE2E: String?
    var compactDecode: String?
    var qualityTitle: String
    var qualityBadges: [String]
    var showsQualityMetadata: Bool
    var qualityMetadataLines: [String]
    var footerUpdatedText: String
    var detailsTitle: String
    var chartSeriesTitles: [String]
    var chartHasOpenBucketGap: Bool
    var chartLineSegments: [[Bool]]

    static func make(
        snapshot: LightSnapshot?,
        trends: TrendSnapshot?,
        qualityExpanded: Bool,
        telemetryEnabled: Bool,
        now: Date? = nil
    ) -> SummaryPopoverProjection {
        let presentation = snapshot.map { LightSnapshotPresentation(snapshot: $0, now: now) }
        let metric = snapshot?.outputThroughput
        let isLive = metric?.tokensPerSecond != nil
            && metric?.dataState != .stale
            && metric?.dataState != .absent
            && metric?.dataState != .unavailable
            && metric?.freshness.isRetained != true
        let performance = snapshot?.performance
        let unavailable = performance.map {
            $0.timeToFirstToken.p50 == nil && $0.endToEnd.p50 == nil && $0.decodeTPS.p50 == nil
        } ?? true
        let showBanner = unavailable && !telemetryEnabled
        let badges = qualityBadges(from: presentation)
        let chart = trends?.outputThroughput
        return SummaryPopoverProjection(
            title: "Agent Metrics",
            windowLabel: presentation?.windowLabel ?? "3m",
            isLive: isLive,
            dataStatus: dataStatus(snapshot: snapshot, presentation: presentation, isLive: isLive),
            agentMenuTitle: menuTitle(prefix: "All agents", chips: presentation?.agentChips ?? [], selectedCount: presentation?.agentActiveCount ?? 0),
            modelMenuTitle: menuTitle(prefix: "All models", chips: presentation?.modelChips ?? [], selectedCount: presentation?.modelActiveCount ?? 0),
            totalValueText: presentation?.valueText ?? "—",
            averageValueText: presentation?.averageValueText ?? "—",
            unitText: presentation?.unitText ?? "tokens/s",
            activeSessionsText: presentation?.activeSessionsText ?? "0 active sessions",
            burnValueText: compactRate(presentation?.burnValueText),
            burnUnitText: "/min",
            callsValueText: compactRate(presentation?.callsValueText),
            callsUnitText: "",
            performance: showBanner ? .banner : .compact,
            performanceBannerText: showBanner ? "Performance metrics require Enhanced Telemetry" : nil,
            performanceActionText: showBanner ? "Enable" : nil,
            compactTTFT: showBanner ? nil : compactPerformance(performance?.timeToFirstToken, unit: "ms"),
            compactE2E: showBanner ? nil : compactPerformance(performance?.endToEnd, unit: "ms"),
            compactDecode: showBanner ? nil : compactPerformance(performance?.decodeTPS, unit: "t/s"),
            qualityTitle: "Data quality & sources",
            qualityBadges: badges,
            showsQualityMetadata: qualityExpanded,
            qualityMetadataLines: qualityExpanded ? metadataLines(presentation) : [],
            footerUpdatedText: presentation?.outputMetadata.freshnessText ?? "No update",
            detailsTitle: "Details",
            chartSeriesTitles: chart?.series.map(\.title) ?? [],
            chartHasOpenBucketGap: chart?.series.contains { series in
                series.buckets.contains { !$0.isComplete && $0.value == nil }
            } ?? false,
            chartLineSegments: chart?.series.map(segmentPresence) ?? []
        )
    }

    private static func menuTitle(prefix: String, chips: [FilterChip], selectedCount: Int) -> String {
        if selectedCount == 0 {
            return prefix
        }
        let selected = chips.filter { $0.id != "all" && $0.isSelected }.map(\.title)
        if selected.count == 1 { return selected[0] }
        return "\(selectedCount) selected"
    }

    private static func compactRate(_ value: String?) -> String {
        guard let value, value != "Unavailable" else { return "—" }
        return value
    }

    private static func compactPerformance(_ distribution: PerformanceDistribution?, unit: String) -> String {
        guard let value = distribution?.p50 else { return "—" }
        if value.rounded() == value {
            return "\(Int(value)) \(unit)"
        }
        return String(format: "%.1f \(unit)", value)
    }

    private static func qualityBadges(from presentation: LightSnapshotPresentation?) -> [String] {
        guard let presentation else { return [] }
        var badges: [String] = []
        if presentation.coverageText == "Partial" {
            badges.append("Partial")
        }
        if presentation.dataStateText == "Stale" {
            badges.append("Stale")
        }
        let limited = presentation.sourceHealthText.split(separator: "·").filter {
            !$0.localizedCaseInsensitiveContains("Healthy")
        }
        if !limited.isEmpty {
            badges.append("\(limited.count) sources limited")
        }
        return badges
    }

    private static func dataStatus(
        snapshot: LightSnapshot?,
        presentation: LightSnapshotPresentation?,
        isLive: Bool
    ) -> DataStatus {
        guard let snapshot, let presentation else { return .unavailable }
        switch snapshot.outputThroughput.dataState {
        case .stale:
            return .stale
        case .absent, .unavailable:
            return .unavailable
        default:
            break
        }
        if presentation.coverageText == "Partial" || snapshot.sourceHealth.contains(where: { !$0.isHealthy }) {
            return .partial
        }
        return isLive ? .live : .unavailable
    }

    private static func metadataLines(_ presentation: LightSnapshotPresentation?) -> [String] {
        guard let metadata = presentation?.outputMetadata else { return [] }
        var lines = [
            "Quality \(metadata.qualityText)",
            "State \(metadata.stateText)",
            "Coverage \(metadata.coverageText)",
            "\(metadata.sourceAuthorityText) · \(metadata.scopeText) · \(metadata.definitionVersionText)",
        ]
        if let lastKnown = presentation?.lastKnownValueText {
            lines.append("Last known \(lastKnown) \(presentation?.unitText ?? "tokens/s")")
        }
        return lines
    }

    private static func segmentPresence(_ series: TrendSeries) -> [Bool] {
        TrendLinePlotPlanning.segments(for: series).map { !$0.points.isEmpty }
    }
}

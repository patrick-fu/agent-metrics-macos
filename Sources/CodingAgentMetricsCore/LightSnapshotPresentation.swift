import Foundation

public struct FilterChip: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isSelected: Bool
    public var action: FilterChipAction

    public init(id: String, title: String, isSelected: Bool, action: FilterChipAction) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }
}

public struct MetricMetadataPresentation: Sendable, Equatable {
    public var qualityText: String
    public var stateText: String
    public var coverageText: String
    public var freshnessText: String
    public var sampleCountText: String
    public var definitionVersionText: String
    public var sourceAuthorityText: String
    public var scopeText: String
    public var reasonText: String?
    public var actionText: String?

    public init(
        quality: MeasurementQuality,
        state: DataState?,
        coverage: Coverage,
        freshness: Freshness,
        sampleCount: Int,
        definitionVersion: String,
        sourceAuthority: String,
        scope: OutputThroughputScope,
        unavailableReason: UnavailableReasonCode?,
        recommendedAction: MetricAction?
    ) {
        qualityText = quality.displayLabel
        stateText = state?.displayLabel ?? "-"
        coverageText = coverage.displayLabel
        freshnessText = Self.freshnessText(freshness)
        sampleCountText = "n \(sampleCount)"
        definitionVersionText = definitionVersion
        sourceAuthorityText = sourceAuthority
        scopeText = scope == .all ? "All" : "Selected"
        reasonText = unavailableReason?.message
        actionText = recommendedAction?.message
    }

    static func freshnessText(_ freshness: Freshness) -> String {
        guard let age = freshness.ageSeconds else { return "No update" }
        let seconds = Int(age.rounded(.down))
        let ageText = seconds < 60 ? "\(seconds)s" : seconds < 3_600 ? "\(seconds / 60)m" : "\(seconds / 3_600)h"
        return "Updated \(ageText) ago\(freshness.isRetained ? " · Retained" : "")"
    }
}

public struct LightSnapshotPresentation: Sendable, Equatable {
    public var title: String
    public var windowLabel: String
    public var valueText: String
    public var unitText: String
    public var averageValueText: String
    public var activeSessionsText: String
    public var lastKnownValueText: String?
    public var menuBarTitleText: String
    public var menuBarAccessibilityLabel: String
    public var qualityText: String
    public var dataStateText: String
    public var coverageText: String
    public var burnValueText: String
    public var burnUnitText: String
    public var burnQualityText: String
    public var burnStateText: String
    public var burnCoverageText: String
    public var burnCompositionText: String
    public var callsValueText: String
    public var callsUnitText: String
    public var callsQualityText: String
    public var callsStateText: String
    public var callsCoverageText: String
    public var callsUnavailableReason: String?
    public var callsDetailText: String
    public var callsWindowLabel: String
    public var agentActiveCount: Int
    public var modelActiveCount: Int
    public var agentChips: [FilterChip]
    public var modelChips: [FilterChip]
    public var outputMetadata: MetricMetadataPresentation
    public var burnMetadata: MetricMetadataPresentation
    public var callsMetadata: MetricMetadataPresentation
    public var sourceHealthText: String
    public var capacityText: String?

    public init(snapshot: LightSnapshot, now: Date? = nil) {
        title = "Output Throughput"
        windowLabel = "\(snapshot.outputThroughput.windowSeconds / 60)m"
        unitText = "tokens/s"
        let metric = snapshot.outputThroughput
        let isLive = metric.tokensPerSecond != nil
            && metric.dataState != .stale
            && metric.dataState != .absent
            && metric.dataState != .unavailable
            && !metric.freshness.isRetained
        lastKnownValueText = (!isLive ? metric.tokensPerSecond : nil).map(Self.format)
        if isLive, let tokensPerSecond = metric.tokensPerSecond {
            valueText = Self.format(tokensPerSecond)
        } else {
            valueText = "—"
        }
        if isLive, let average = metric.averageTokensPerSecond {
            averageValueText = Self.format(average)
        } else {
            averageValueText = "—"
        }
        activeSessionsText = metric.activeSessionCount == 1
            ? "1 active session"
            : "\(metric.activeSessionCount) active sessions"
        if isLive, let tokensPerSecond = metric.tokensPerSecond {
            menuBarTitleText = Self.menuBarTitle(tokensPerSecond)
        } else {
            menuBarTitleText = "—"
        }
        menuBarAccessibilityLabel = Self.menuBarAccessibilityLabel(
            title: title,
            windowLabel: windowLabel,
            valueText: isLive ? valueText : nil,
            averageValueText: isLive ? averageValueText : nil,
            activeSessionsText: activeSessionsText,
            isLive: isLive
        )
        qualityText = snapshot.outputThroughput.measurementQuality.displayLabel
        dataStateText = snapshot.outputThroughput.dataState?.displayLabel ?? "-"
        coverageText = snapshot.outputThroughput.coverage.displayLabel
        let displayNow = now ?? snapshot.generatedAt
        let outputFreshness = Freshness.observed(
            at: snapshot.outputThroughput.freshness.lastUpdatedAt,
            now: displayNow,
            retained: snapshot.outputThroughput.freshness.isRetained
        )
        outputMetadata = MetricMetadataPresentation(
            quality: snapshot.outputThroughput.measurementQuality,
            state: snapshot.outputThroughput.dataState,
            coverage: snapshot.outputThroughput.coverage,
            freshness: outputFreshness,
            sampleCount: snapshot.outputThroughput.sampleCount,
            definitionVersion: snapshot.outputThroughput.definitionVersion,
            sourceAuthority: snapshot.outputThroughput.sourceAuthority,
            scope: snapshot.outputThroughput.scope,
            unavailableReason: snapshot.outputThroughput.unavailableReason,
            recommendedAction: snapshot.outputThroughput.recommendedAction
        )
        burnValueText = snapshot.tokenBurn.tokensPerMinute.map(Self.format) ?? "Unavailable"
        burnUnitText = "tokens/min"
        burnQualityText = snapshot.tokenBurn.measurementQuality.displayLabel
        burnStateText = snapshot.tokenBurn.dataState?.displayLabel ?? "-"
        burnCoverageText = snapshot.tokenBurn.coverage.displayLabel
        burnCompositionText = Self.composition(snapshot.tokenBurn.parts)
        burnMetadata = MetricMetadataPresentation(
            quality: snapshot.tokenBurn.measurementQuality,
            state: snapshot.tokenBurn.dataState,
            coverage: snapshot.tokenBurn.coverage,
            freshness: snapshot.tokenBurn.freshness,
            sampleCount: snapshot.tokenBurn.sampleCount,
            definitionVersion: snapshot.tokenBurn.definitionVersion,
            sourceAuthority: snapshot.tokenBurn.sourceAuthority,
            scope: snapshot.tokenBurn.scope,
            unavailableReason: snapshot.tokenBurn.unavailableReason,
            recommendedAction: snapshot.tokenBurn.recommendedAction
        )
        callsValueText = snapshot.calls.callsPerMinute.map(Self.format) ?? "Unavailable"
        callsUnitText = "calls/min"
        callsQualityText = snapshot.calls.measurementQuality.displayLabel
        callsStateText = snapshot.calls.dataState?.displayLabel ?? "-"
        callsCoverageText = snapshot.calls.coverage.displayLabel
        callsUnavailableReason = snapshot.calls.dataState == .unavailable ? snapshot.calls.unavailableReason?.message : nil
        if let callCount = snapshot.calls.selectedCallCount {
            callsDetailText = "\(callCount) distinct stable Model Call IDs"
        } else {
            callsDetailText = callsUnavailableReason ?? "Unavailable"
        }
        callsWindowLabel = "\(snapshot.calls.windowSeconds / 60)m"
        callsMetadata = MetricMetadataPresentation(
            quality: snapshot.calls.measurementQuality,
            state: snapshot.calls.dataState,
            coverage: snapshot.calls.coverage,
            freshness: snapshot.calls.freshness,
            sampleCount: snapshot.calls.sampleCount,
            definitionVersion: snapshot.calls.definitionVersion,
            sourceAuthority: snapshot.calls.sourceAuthority,
            scope: snapshot.calls.scope,
            unavailableReason: snapshot.calls.unavailableReason,
            recommendedAction: snapshot.calls.recommendedAction
        )
        sourceHealthText = snapshot.sourceHealth.isEmpty ? "Source health unavailable" : snapshot.sourceHealth.map { health in
            "\(health.sourceID): \(health.isHealthy ? "Healthy" : health.reasonCode?.rawValue ?? "Degraded")"
        }.joined(separator: " · ")
        capacityText = switch snapshot.retentionStatus?.level {
        case .warning:
            "Capacity warning: telemetry storage is approaching its hard limit."
        case .hardLimit:
            snapshot.retentionStatus?.diagnosticCode == RetentionManager.protectedWindowDiagnostic
                ? "Ingestion paused: the protected seven-day window reached capacity. Reset Data to resume."
                : "Ingestion paused: telemetry storage reached its hard limit."
        case .normal, .none:
            nil
        }
        agentActiveCount = snapshot.filter.agents.activeCount
        modelActiveCount = snapshot.filter.models.activeCount
        agentChips = Self.chips(
            options: snapshot.codingAgents.map { ($0.rawValue, $0.displayName) },
            axis: snapshot.filter.agents
        )
        modelChips = Self.chips(
            options: snapshot.modelIdentities.map { ($0.raw, $0.display) },
            axis: snapshot.filter.models
        )
    }

    private static func chips(
        options: [(id: String, title: String)],
        axis: SelectionAxis<String>
    ) -> [FilterChip] {
        [FilterChip(id: "all", title: "All", isSelected: axis.isAll, action: .selectAll)]
            + options.map { option in
                FilterChip(
                    id: "value:\(option.id)",
                    title: option.title,
                    isSelected: !axis.isAll && axis.selected.contains(option.id),
                    action: .toggle(option.id)
                )
            }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    static func menuBarTitle(_ value: Double) -> String {
        if abs(value) >= 1_000 {
            let thousands = value / 1_000
            if (thousands * 10).rounded() / 10 == thousands.rounded() {
                return "\(Int(thousands.rounded()))k t/s"
            }
            return String(format: "%.1fk t/s", thousands)
        }
        return "\(format(value)) t/s"
    }

    private static func menuBarAccessibilityLabel(
        title: String,
        windowLabel: String,
        valueText: String?,
        averageValueText: String?,
        activeSessionsText: String,
        isLive: Bool
    ) -> String {
        guard isLive, let valueText, let averageValueText else {
            return "\(title) unavailable"
        }
        return "\(title) \(valueText) tokens/s over \(windowLabel), average \(averageValueText) tokens/s, \(activeSessionsText)"
    }

    private static func composition(_ parts: TokenParts?) -> String {
        guard let parts else { return "Unavailable" }
        func item(_ title: String, _ value: Int?) -> String {
            let label = value.map(String.init) ?? "Unavailable"
            return "\(title) \(label)"
        }
        return [
            item("Input uncached", parts.inputUncached),
            item("Cache read", parts.cacheRead),
            item("Cache write", parts.cacheWrite),
            item("Output visible", parts.outputVisible),
            item("Reasoning", parts.reasoning),
        ].joined(separator: " · ")
    }
}

extension MeasurementQuality {
    var displayLabel: String {
        switch self {
        case .measured: "Measured"
        case .derived: "Derived"
        case .estimated: "Estimated"
        case .unavailable: "Unavailable"
        }
    }
}

extension DataState {
    var displayLabel: String {
        switch self {
        case .zero: "Zero"
        case .stale: "Stale"
        case .absent: "No data"
        case .unavailable: "Unavailable"
        }
    }
}

extension Coverage {
    var displayLabel: String {
        switch self {
        case .complete: "Complete"
        case .partial: "Partial"
        }
    }
}

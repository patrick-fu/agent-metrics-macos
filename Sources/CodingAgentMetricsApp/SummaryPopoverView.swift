import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import SwiftUI

@MainActor
final class RuntimeSnapshots: ObservableObject {
    @Published var light: LightSnapshot?
    @Published var detail: TrendSnapshot?

    init(light: LightSnapshot? = nil, detail: TrendSnapshot? = nil) {
        self.light = light
        self.detail = detail
    }
}

struct SummaryPopoverView: View {
    private enum Activity: String, CaseIterable, Identifiable {
        case burn = "Burn"
        case calls = "Calls"
        var id: String { rawValue }
    }

    @ObservedObject private var snapshots: RuntimeSnapshots
    @State private var showsTrends = false
    @State private var activity: Activity = .burn
    @State private var performanceRange: PerformanceRange = .oneHour
    @State private var requestedFilter: MetricFilter
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController
    var loadSnapshot: (MetricFilter, PerformanceRange) -> Void
    var loadTrends: (MetricFilter) -> Void
    private var snapshot: LightSnapshot? { snapshots.light }
    private var trends: TrendSnapshot? { snapshots.detail }

    init(
        snapshot: LightSnapshot?,
        snapshots: RuntimeSnapshots? = nil,
        lifecycleServices: AppLifecycleServices = .live,
        telemetry: EnhancedTelemetryController? = nil,
        loadSnapshot: @escaping (MetricFilter, PerformanceRange) -> Void = { _, _ in },
        loadTrends: @escaping (MetricFilter) -> Void = { _ in }
    ) {
        _snapshots = ObservedObject(wrappedValue: snapshots ?? RuntimeSnapshots(light: snapshot))
        _requestedFilter = State(initialValue: snapshot?.filter ?? .all)
        self.lifecycleServices = lifecycleServices
        self.telemetry = telemetry ?? EnhancedTelemetryController(runtime: nil)
        self.loadSnapshot = loadSnapshot
        self.loadTrends = loadTrends
    }

    var body: some View {
        if showsTrends {
            trendsDetail
        } else {
            summary
        }
    }

    @ViewBuilder private var summary: some View {
        let presentation = snapshot.map(LightSnapshotPresentation.init)
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding Agent Metrics")
                .font(.headline)
            filterRow(
                title: "Agent",
                chips: presentation?.agentChips ?? [
                    FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                ],
                count: presentation?.agentActiveCount ?? 0,
                axis: .agent
            )
            filterRow(
                title: "Model",
                chips: presentation?.modelChips ?? [
                    FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                ],
                count: presentation?.modelActiveCount ?? 0,
                axis: .model
            )
            HStack(spacing: 8) {
                kpi(title: "Token Burn/min", value: presentation?.burnValueText ?? "Unavailable", unit: presentation?.burnUnitText ?? "tokens/min")
                kpi(title: "Calls/min", value: presentation?.callsValueText ?? "Unavailable", unit: presentation?.callsUnitText ?? "calls/min")
            }
            performance(snapshot?.performance)
            Picker("Activity", selection: $activity) {
                ForEach(Activity.allCases) { activity in
                    Text(activity.rawValue).tag(activity)
                }
            }
            .pickerStyle(.segmented)
            activityDetail(presentation)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(presentation?.title ?? "Output Throughput")
                        .font(.subheadline)
                    Spacer()
                    Text(presentation?.windowLabel ?? "3m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(presentation?.valueText ?? "-")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(presentation?.unitText ?? "tokens/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            metricMetadata(presentation?.outputMetadata)
            Text(presentation?.sourceHealthText ?? "Source health unavailable")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("View Trends") {
                guard snapshot != nil else { return }
                showsTrends = true
                loadTrends(requestedFilter)
            }
            .accessibilityHint("Opens trend charts and exact values")
            SettingsView(lifecycleServices: lifecycleServices, telemetry: telemetry)
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
    }

    private var trendsDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back") { showsTrends = false }
                Spacer()
                Text("Trends").font(.headline)
            }
            if let trends, let presentation = snapshot.map(LightSnapshotPresentation.init) {
                trendSection(
                    title: "Output Throughput",
                    aggregate: "\(presentation.valueText) \(presentation.unitText)",
                    chart: trends.outputThroughput,
                    style: .line
                )
                Picker("Activity", selection: $activity) {
                    ForEach(Activity.allCases) { activity in Text(activity.rawValue).tag(activity) }
                }
                .pickerStyle(.segmented)
                trendSection(
                    title: activity == .burn ? "Token Burn" : "Calls",
                    aggregate: activity == .burn ? "\(presentation.burnValueText) \(presentation.burnUnitText)" : "\(presentation.callsValueText) \(presentation.callsUnitText)",
                    chart: activity == .burn ? trends.tokenBurn : trends.calls,
                    style: activity == .burn ? .burnParts : .calls
                )
            } else {
                Text("Trends unavailable").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
        .onExitCommand { showsTrends = false }
    }

    private func trendSection(title: String, aggregate: String, chart: TrendChart, style: TrendChartView.Style) -> some View {
        let presentation = TrendPresentation(chart: chart)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(aggregate).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("\(presentation.qualityText) · \(presentation.dataStateText) · \(presentation.coverageText) · \(presentation.sampleCountText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(presentation.freshnessText) · \(presentation.sourceAuthorityText) · \(presentation.scopeText) · \(presentation.definitionVersionText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let reason = presentation.reasonText {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            if let action = presentation.actionText {
                Text(action).font(.caption2).foregroundStyle(.tint)
            }
            TrendChartView(chart: chart, style: style)
        }
    }

    @ViewBuilder
    private func activityDetail(_ presentation: LightSnapshotPresentation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if activity == .burn {
                Text("Burn composition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation?.burnCompositionText ?? "Unavailable")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                metricMetadata(presentation?.burnMetadata)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation?.callsDetailText ?? "Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(presentation?.callsWindowLabel ?? "10m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                metricMetadata(presentation?.callsMetadata)
            }
        }
    }

    private func kpi(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04))
    }

    private func filterRow(title: String, chips: [FilterChip], count: Int, axis: FilterAxis) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(count == 0 ? title : "\(title) \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
                .accessibilityLabel(count == 0 ? "\(title) filter" : "\(title) filter, \(count) selected")
            Menu {
                ForEach(chips) { chip in
                    Button {
                        apply(chip.action, on: axis)
                    } label: {
                        if chip.isSelected {
                            Label(chip.title, systemImage: "checkmark")
                        } else {
                            Text(chip.title)
                        }
                    }
                    .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("\(title) filter menu")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        Button(chip.title) {
                            apply(chip.action, on: axis)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chip.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .overlay(
                            Capsule().stroke(chip.isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                        )
                        .clipShape(Capsule())
                        .accessibilityLabel(chip.title)
                        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func apply(_ action: FilterChipAction, on axis: FilterAxis) {
        requestedFilter.apply(action, on: axis)
        loadSnapshot(requestedFilter, performanceRange)
    }

    private func performance(_ metric: PerformanceSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Performance")
                    .font(.subheadline)
                Spacer()
                Picker("Performance range", selection: $performanceRange) {
                    ForEach(PerformanceRange.allCases, id: \.self) { range in
                        Text(range.label).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: performanceRange) { _, range in
                    reloadPerformance(range)
                }
            }
            HStack(spacing: 6) {
                performanceKPI("TTFT", metric?.timeToFirstToken, secondary: "p95")
                performanceKPI("E2E", metric?.endToEnd, secondary: "p95")
                performanceKPI("Decode TPS", metric?.decodeTPS, secondary: "p10")
            }
            if let metric, metric.retryCount > 0 || metric.invalidDecodeCount > 0 {
                Text("Retries excluded: \(metric.retryCount) · Invalid decode: \(metric.invalidDecodeCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let reason = metric?.unavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func performanceKPI(_ title: String, _ metric: PerformanceDistribution?, secondary: String) -> some View {
        let kind: PerformanceMetricKind = title == "TTFT" ? .timeToFirstToken : (title == "E2E" ? .endToEnd : .decodeTPS)
        let presentation = metric.map { PerformanceMetricPresentation(kind: kind, distribution: $0) }
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(presentation?.valueText ?? "Unavailable") \(presentation?.unitText ?? (kind == .decodeTPS ? "tokens/s" : "ms"))")
                .font(.caption.weight(.semibold)).monospacedDigit()
            Text(presentation?.secondaryText ?? "p50 · \(secondary) - · n 0")
                .font(.caption2).foregroundStyle(.secondary)
            Text(presentation?.qualityText ?? "Unavailable")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(presentation?.stateText ?? "Unavailable") · \(presentation?.coverageText ?? "Partial")")
                .font(.caption2).foregroundStyle(.secondary)
            Text(presentation?.freshnessText ?? "No update")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(presentation?.sourceAuthorityText ?? "unavailable") · \(presentation?.scopeText ?? "All") · \(presentation?.definitionVersionText ?? "unavailable")")
                .font(.caption2).foregroundStyle(.secondary)
            if let lowSample = presentation?.lowSampleText {
                Text(lowSample).font(.caption2).foregroundStyle(.orange)
            }
            if let reason = presentation?.reasonText {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            if let action = presentation?.actionText {
                Text(action).font(.caption2).foregroundStyle(.tint)
            }
        }
        .accessibilityHint(presentation?.accessibilityHint ?? "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.primary.opacity(0.04))
    }

    private func reloadPerformance(_ range: PerformanceRange) {
        guard snapshot != nil else { return }
        loadSnapshot(requestedFilter, range)
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func meta(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private func metricMetadata(_ metadata: MetricMetadataPresentation?) -> some View {
        if let metadata {
            HStack(spacing: 8) {
                meta(title: "Quality", value: metadata.qualityText)
                meta(title: "State", value: metadata.stateText)
                meta(title: "Coverage", value: metadata.coverageText)
            }
            Text("\(metadata.freshnessText) · \(metadata.sampleCountText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(metadata.sourceAuthorityText) · \(metadata.scopeText) · \(metadata.definitionVersionText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let reason = metadata.reasonText {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            if let action = metadata.actionText {
                Text(action).font(.caption2).foregroundStyle(.tint)
            }
        }
    }
}

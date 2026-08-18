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
    @ObservedObject private var snapshots: RuntimeSnapshots
    @ObservedObject private var accessibility: AccessibilitySession
    @FocusState private var focusedControl: AccessibilityNavigation.Control?
    @State private var performanceRange: PerformanceRange = .oneHour
    @State private var requestedFilter: MetricFilter
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController
    let resetData: ResetDataController
    let diagnostics: DiagnosticActionController
    var loadSnapshot: (MetricFilter, PerformanceRange) -> Void
    var loadTrends: (MetricFilter) -> Void
    private var snapshot: LightSnapshot? { snapshots.light }
    private var trends: TrendSnapshot? { snapshots.detail }

    init(
        snapshot: LightSnapshot?,
        snapshots: RuntimeSnapshots? = nil,
        accessibility: AccessibilitySession? = nil,
        lifecycleServices: AppLifecycleServices = .live,
        telemetry: EnhancedTelemetryController? = nil,
        resetData: ResetDataController? = nil,
        diagnostics: DiagnosticActionController? = nil,
        loadSnapshot: @escaping (MetricFilter, PerformanceRange) -> Void = { _, _ in },
        loadTrends: @escaping (MetricFilter) -> Void = { _ in }
    ) {
        _snapshots = ObservedObject(wrappedValue: snapshots ?? RuntimeSnapshots(light: snapshot))
        _accessibility = ObservedObject(wrappedValue: accessibility ?? AccessibilitySession())
        _requestedFilter = State(initialValue: snapshot?.filter ?? .all)
        self.lifecycleServices = lifecycleServices
        self.telemetry = telemetry ?? EnhancedTelemetryController(runtime: nil)
        self.resetData = resetData ?? ResetDataController()
        self.diagnostics = diagnostics ?? DiagnosticActionController(
            generate: { throw DiagnosticActionError.snapshotUnavailable },
            copy: { _ in },
            userSelectedSave: { _ in false }
        )
        self.loadSnapshot = loadSnapshot
        self.loadTrends = loadTrends
    }

    var body: some View {
        Group {
            switch accessibility.surface {
            case .trends:
                trendsDetail
            case .settings, .diagnosticsConfirmation, .resetConfirmation:
                settingsDetail
            case .dismissed, .summary:
                summary
            }
        }
        .onAppear { syncFocus() }
        .onChange(of: accessibility.navigation.focusedControl) { _, _ in syncFocus() }
        .onExitCommand(perform: handleEscape)
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
                axis: .agent,
                control: .agentFilter
            )
            filterRow(
                title: "Model",
                chips: presentation?.modelChips ?? [
                    FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                ],
                count: presentation?.modelActiveCount ?? 0,
                axis: .model,
                control: .modelFilter
            )
            HStack(spacing: 8) {
                kpi(title: "Token Burn/min", value: presentation?.burnValueText ?? "Unavailable", unit: presentation?.burnUnitText ?? "tokens/min")
                kpi(title: "Calls/min", value: presentation?.callsValueText ?? "Unavailable", unit: presentation?.callsUnitText ?? "calls/min")
            }
            performance(snapshot?.performance)
            Picker("Activity", selection: accessibility.activityBinding) {
                Text(AccessibilityNavigation.ActivityMetric.burn.rawValue)
                    .tag(AccessibilityNavigation.ActivityMetric.burn)
                Text(AccessibilityNavigation.ActivityMetric.calls.rawValue)
                    .tag(AccessibilityNavigation.ActivityMetric.calls)
            }
            .pickerStyle(.segmented)
            .focused($focusedControl, equals: .activityPicker)
            .accessibilityFocusChrome(focusedControl == .activityPicker)
            .accessibilityLabel("Activity")
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
            if let capacityText = presentation?.capacityText {
                Text(capacityText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(capacityText)
            }
            HStack {
                Button("View Trends") {
                    accessibility.activate(.viewTrends)
                    loadTrends(requestedFilter)
                }
                .focused($focusedControl, equals: .viewTrends)
                .accessibilityFocusChrome(focusedControl == .viewTrends)
                .accessibilityHint("Opens trend charts and exact values")
                Button("Settings") {
                    accessibility.activate(.settings)
                }
                .focused($focusedControl, equals: .settings)
                .accessibilityFocusChrome(focusedControl == .settings)
                .accessibilityHint("Opens login, telemetry, diagnostics, reset, and update controls")
            }
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
    }

    private var settingsDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back") { handleEscape() }
                    .focused($focusedControl, equals: .back)
                    .accessibilityFocusChrome(focusedControl == .back)
                Spacer()
                Text("Settings").font(.headline)
            }
            SettingsView(
                lifecycleServices: lifecycleServices,
                telemetry: telemetry,
                resetData: resetData,
                diagnostics: diagnostics,
                accessibility: accessibility
            )
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
    }

    private var trendsDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back") { handleEscape() }
                    .focused($focusedControl, equals: .back)
                    .accessibilityFocusChrome(focusedControl == .back)
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
                Picker("Activity", selection: accessibility.activityBinding) {
                    Text(AccessibilityNavigation.ActivityMetric.burn.rawValue)
                        .tag(AccessibilityNavigation.ActivityMetric.burn)
                    Text(AccessibilityNavigation.ActivityMetric.calls.rawValue)
                        .tag(AccessibilityNavigation.ActivityMetric.calls)
                }
                .pickerStyle(.segmented)
                .focused($focusedControl, equals: .activityPicker)
                .accessibilityFocusChrome(focusedControl == .activityPicker)
                .accessibilityLabel("Activity")
                trendSection(
                    title: ActivitySurfaceProjection.make(navigation: accessibility.navigation, trends: trends).selected == .calls ? "Calls" : "Token Burn",
                    aggregate: ActivitySurfaceProjection.make(navigation: accessibility.navigation, trends: trends).selected == .calls ? "\(presentation.callsValueText) \(presentation.callsUnitText)" : "\(presentation.burnValueText) \(presentation.burnUnitText)",
                    chart: ActivitySurfaceProjection.make(navigation: accessibility.navigation, trends: trends).selected == .calls ? trends.calls : trends.tokenBurn,
                    style: ActivitySurfaceProjection.make(navigation: accessibility.navigation, trends: trends).chartStyle
                )
            } else {
                Text("Trends unavailable").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
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
            TrendChartView(
                chart: chart,
                style: style,
                isTableFocused: focusedControl == tableControl(for: style),
                onTableFocused: { accessibility.activate(tableControl(for: style)) }
            )
            .focused($focusedControl, equals: tableControl(for: style))
            .accessibilityFocusChrome(focusedControl == tableControl(for: style))
        }
    }

    @ViewBuilder
    private func activityDetail(_ presentation: LightSnapshotPresentation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if accessibility.navigation.activity == .burn {
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

    private func filterRow(
        title: String,
        chips: [FilterChip],
        count: Int,
        axis: FilterAxis,
        control: AccessibilityNavigation.Control
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(count == 0 ? title : "\(title) \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
                .accessibilityLabel(count == 0 ? "\(title) filter" : "\(title) filter, \(count) selected")
            Menu {
                ForEach(chips) { chip in
                    Button {
                        accessibility.activate(control)
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
            .focused($focusedControl, equals: control)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        Button(chip.title) {
                            accessibility.activate(control)
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
        .focused($focusedControl, equals: control)
        .accessibilityFocusChrome(focusedControl == control)
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
                .focused($focusedControl, equals: .performanceRange)
                .accessibilityFocusChrome(focusedControl == .performanceRange)
                .onChange(of: performanceRange) { _, range in
                    accessibility.activate(.performanceRange)
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

    private func handleEscape() {
        switch accessibility.surface {
        case .diagnosticsConfirmation(let action):
            diagnostics.cancel(confirmation(for: action))
        case .resetConfirmation:
            resetData.cancelReset()
        default:
            break
        }
        accessibility.escape()
    }

    private func syncFocus() {
        let control = accessibility.focusedControl
        focusedControl = control == .statusItem ? nil : control
    }

    private func tableControl(for style: TrendChartView.Style) -> AccessibilityNavigation.Control {
        style == .line ? .outputTable : .activityTable
    }

    private func confirmation(for action: AccessibilityNavigation.DiagnosticsAction) -> DiagnosticActionController.Confirmation {
        switch action {
        case .copy: .copy
        case .save: .save
        case .preparePublicIssue: .preparePublicIssue
        }
    }
}

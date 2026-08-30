import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import SwiftUI

struct DetailSnapshotLoadGate: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isLoading = false

    mutating func beginRequest() -> UInt64 {
        generation &+= 1
        isLoading = true
        return generation
    }

    mutating func finish(generation: UInt64) -> Bool {
        guard generation == self.generation, isLoading else { return false }
        isLoading = false
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        isLoading = false
    }
}

enum DetailSurfaceAvailability: Equatable {
    case loading
    case empty
    case content

    static func make(inFlight: Bool, snapshot: TrendSnapshot?) -> Self {
        if snapshot != nil { return .content }
        return inFlight ? .loading : .empty
    }
}

@MainActor
final class RuntimeSnapshots: ObservableObject {
    @Published var light: LightSnapshot?
    @Published var detail: TrendSnapshot?
    @Published var isDetailLoading: Bool

    init(light: LightSnapshot? = nil, detail: TrendSnapshot? = nil, isDetailLoading: Bool = false) {
        self.light = light
        self.detail = detail
        self.isDetailLoading = isDetailLoading
    }

    var showsTrendsLoading: Bool {
        DetailSurfaceAvailability.make(inFlight: isDetailLoading, snapshot: detail) == .loading
    }
}

struct SummaryPopoverView: View {
    @ObservedObject private var snapshots: RuntimeSnapshots
    @ObservedObject private var accessibility: AccessibilitySession
    @FocusState private var focusedControl: AccessibilityNavigation.Control?
    @State private var performanceRange: PerformanceRange = .oneHour
    @State private var requestedFilter: MetricFilter
    @State private var qualityExpanded = false
    @State private var now: Date
    @ObservedObject private var preferences: DisplayPreferencesController
    var clock: any Clock
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController
    let resetData: ResetDataController
    let diagnostics: DiagnosticActionController
    var loadSnapshot: (MetricFilter, PerformanceRange) -> Void
    var loadTrends: (MetricFilter) -> Void
    var onWindowChange: (OutputThroughputWindow) -> Void
    var onCadenceChange: (DisplayCadence) -> Void
    private var snapshot: LightSnapshot? { snapshots.light }
    private var trends: TrendSnapshot? { snapshots.detail }
    var showsTrendsLoading: Bool { snapshots.showsTrendsLoading }

    init(
        snapshot: LightSnapshot?,
        snapshots: RuntimeSnapshots? = nil,
        accessibility: AccessibilitySession? = nil,
        lifecycleServices: AppLifecycleServices = .live,
        telemetry: EnhancedTelemetryController? = nil,
        resetData: ResetDataController? = nil,
        diagnostics: DiagnosticActionController? = nil,
        loadSnapshot: @escaping (MetricFilter, PerformanceRange) -> Void = { _, _ in },
        loadTrends: @escaping (MetricFilter) -> Void = { _ in },
        preferences: DisplayPreferencesController? = nil,
        clock: any Clock = SystemClock(),
        onWindowChange: @escaping (OutputThroughputWindow) -> Void = { _ in },
        onCadenceChange: @escaping (DisplayCadence) -> Void = { _ in }
    ) {
        _snapshots = ObservedObject(wrappedValue: snapshots ?? RuntimeSnapshots(light: snapshot))
        _accessibility = ObservedObject(wrappedValue: accessibility ?? AccessibilitySession())
        _requestedFilter = State(initialValue: snapshot?.filter ?? .all)
        _preferences = ObservedObject(wrappedValue: preferences ?? DisplayPreferencesController())
        self.clock = clock
        _now = State(initialValue: clock.now)
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
        self.onWindowChange = onWindowChange
        self.onCadenceChange = onCadenceChange
    }

    var body: some View {
        Group {
            switch accessibility.surface {
            case .trends:
                trendsSurface
            case .settings:
                secondarySurface(title: "Settings") {
                    SettingsSurfaceView(
                        lifecycleServices: lifecycleServices,
                        telemetry: telemetry,
                        accessibility: accessibility,
                        selectedWindow: $preferences.window,
                        selectedCadence: $preferences.cadence,
                        onWindowChange: onWindowChange,
                        onCadenceChange: onCadenceChange,
                        openDataDiagnostics: { accessibility.activate(.openDataDiagnostics) },
                        openAboutUpdates: { accessibility.activate(.openAboutUpdates) }
                    )
                }
            case .dataDiagnostics, .diagnosticsConfirmation, .resetConfirmation:
                secondarySurface(title: "Data & Diagnostics", scrolls: true) {
                    DataDiagnosticsSurfaceView(
                        diagnostics: diagnostics,
                        resetData: resetData,
                        accessibility: accessibility,
                        onResetCompleted: { diagnostics.clearEphemeralState() }
                    )
                }
            case .aboutUpdates:
                secondarySurface(title: "About & Updates", scrolls: true) {
                    AboutUpdatesSurfaceView(
                        updates: lifecycleServices.updates,
                        accessibility: accessibility
                    )
                }
            case .dismissed, .summary:
                summary
            }
        }
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { syncFocus(); now = clock.now }
        .onChange(of: accessibility.navigation.focusedControl) { _, _ in syncFocus() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            now = clock.now
        }
        .onExitCommand(perform: handleEscape)
    }

    /// Keeps the loading route testable at the same seam the body renders.
    /// A refresh with an existing detail remains content; only an empty in-flight
    /// request presents the loading state.
    var trendsSurface: TrendsSurfaceView {
        TrendsSurfaceView(
            snapshot: snapshot,
            trends: trends,
            accessibility: accessibility,
            isLoading: showsTrendsLoading,
            onBack: handleEscape
        )
    }

    @ViewBuilder private var summary: some View {
        let projection = SummaryPopoverProjection.make(
            snapshot: snapshot,
            trends: trends,
            qualityExpanded: qualityExpanded,
            telemetryEnabled: telemetry.isEnabled,
            now: now
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(projection)
                HStack(spacing: 8) {
                    compactFilter(title: projection.agentMenuTitle, chips: snapshot.map { LightSnapshotPresentation(snapshot: $0) }?.agentChips ?? [
                        FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                    ], axis: .agent, control: .agentFilter)
                    compactFilter(title: projection.modelMenuTitle, chips: snapshot.map { LightSnapshotPresentation(snapshot: $0) }?.modelChips ?? [
                        FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                    ], axis: .model, control: .modelFilter)
                }
                HStack(spacing: 8) {
                    heroCard(title: "TOTAL", value: projection.totalValueText, unit: projection.unitText, isPrimary: true)
                    heroCard(title: "AVG / SESSION", value: projection.averageValueText, unit: projection.unitText, isPrimary: false)
                }
                Label(projection.activeSessionsText, systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                    .accessibilityLabel(projection.activeSessionsText)
                summaryChart(projection)
                HStack(spacing: 8) {
                    smallMetric(title: "Token burn", value: projection.burnValueText, unit: projection.burnUnitText)
                    smallMetric(title: "Calls", value: projection.callsValueText, unit: projection.callsUnitText)
                }
                performanceBanner(projection)
                qualityRow(projection)
                if let capacityText = (snapshot.map { LightSnapshotPresentation(snapshot: $0) })?.capacityText {
                    Text(capacityText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(capacityText)
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(projection.footerUpdatedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.68))
                    Spacer()
                    Button(projection.detailsTitle) {
                        accessibility.activate(.viewTrends)
                        loadTrends(requestedFilter)
                    }
                    .focused($focusedControl, equals: .viewTrends)
                    .accessibilityFocusChrome(focusedControl == .viewTrends)
                    .accessibilityHint("Opens trend charts and exact values")
                }
            }
            .padding(14)
        }
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
        .frame(maxHeight: 720)
        .background(.regularMaterial)
        .onAppear { accessibility.setShowsPerformanceEnable(projection.performance == .banner) }
        .onChange(of: projection.performance) { _, mode in
            accessibility.setShowsPerformanceEnable(mode == .banner)
        }
    }

    @ViewBuilder
    private func secondarySurface<Content: View>(
        title: String,
        scrolls: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back") { handleEscape() }
                    .focused($focusedControl, equals: .back)
                    .accessibilityFocusChrome(focusedControl == .back)
                Spacer()
                Text(title).font(.headline)
            }
            if scrolls {
                ScrollView {
                    content()
                }
                .frame(maxHeight: 720)
            } else {
                content()
            }
        }
        .padding(14)
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
        .frame(maxHeight: 720)
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
            if let trends, let presentation = (snapshot.map { LightSnapshotPresentation(snapshot: $0) }) {
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
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
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
            statusPill(status(fromDataState: presentation.dataStateText, coverage: presentation.coverageText))
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

    private func header(_ projection: SummaryPopoverProjection) -> some View {
        HStack(spacing: 8) {
            Text(projection.title)
                .font(.headline)
                .accessibilityIdentifier("summary-title")
            Spacer()
            statusPill(projection.dataStatus)
            Menu {
                ForEach(OutputThroughputWindow.allCases, id: \.self) { window in
                    Button(window.menuLabel) {
                        preferences.window = window
                        accessibility.activate(.windowSelector)
                        onWindowChange(window)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(preferences.window.menuLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .focused($focusedControl, equals: .windowSelector)
            .accessibilityFocusChrome(focusedControl == .windowSelector)
            .accessibilityLabel("Window \(preferences.window.menuLabel)")
            Button {
                accessibility.activate(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .settings)
            .accessibilityFocusChrome(focusedControl == .settings)
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens login, telemetry, diagnostics, reset, and update controls")
        }
    }

    private func compactFilter(
        title: String,
        chips: [FilterChip],
        axis: FilterAxis,
        control: AccessibilityNavigation.Control
    ) -> some View {
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
            }
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
        .focused($focusedControl, equals: control)
        .accessibilityFocusChrome(focusedControl == control)
        .accessibilityLabel(axis == .agent ? "Agent filter menu" : "Model filter menu")
        .frame(maxWidth: .infinity)
    }

    private func heroCard(title: String, value: String, unit: String, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPrimary ? Color.accentColor : .secondary)
            Text(value)
                .font(.system(size: isPrimary ? 36 : 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            isPrimary ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder
    private func summaryChart(_ projection: SummaryPopoverProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chart = trends?.outputThroughput {
                CompactThroughputChartView(chart: chart)
                .frame(height: 230)
                .accessibilityIdentifier("summary-output-chart")
            } else {
                Text("Chart unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { loadTrends(requestedFilter) }
    }

    private func smallMetric(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func performanceBanner(_ projection: SummaryPopoverProjection) -> some View {
        if projection.performance == .banner {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .foregroundStyle(.tint)
                Text(projection.performanceBannerText ?? "Performance metrics require Enhanced Telemetry")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(projection.performanceActionText ?? "Enable") {
                    accessibility.activate(.performanceEnable)
                    telemetry.setEnabled(true)
                }
                .focused($focusedControl, equals: .performanceEnable)
                .accessibilityFocusChrome(focusedControl == .performanceEnable)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 8) {
                compactPerf("TTFT", projection.compactTTFT)
                compactPerf("E2E", projection.compactE2E)
                compactPerf("Decode TPS", projection.compactDecode)
            }
        }
    }

    private func compactPerf(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private func qualityRow(_ projection: SummaryPopoverProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                qualityExpanded.toggle()
                accessibility.activate(.qualityDisclosure)
            } label: {
                HStack {
                    Text(projection.qualityTitle)
                        .font(.caption)
                    Spacer()
                    ForEach(projection.qualityBadges, id: \.self) { badge in
                        qualityPill(badge)
                    }
                    Image(systemName: qualityExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .qualityDisclosure)
            .accessibilityFocusChrome(focusedControl == .qualityDisclosure)
            .accessibilityLabel(projection.qualityTitle)
            if projection.showsQualityMetadata {
                ForEach(projection.qualityMetadataLines, id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusPill(_ status: SummaryPopoverProjection.DataStatus) -> some View {
        Label(status.label, systemImage: statusIcon(for: status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor(for: status))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(statusColor(for: status).opacity(0.12), in: Capsule())
            .accessibilityLabel(status.label)
    }

    private func qualityPill(_ badge: String) -> some View {
        let status: SummaryPopoverProjection.DataStatus = badge == "Stale" ? .stale : .partial
        return Label(badge, systemImage: statusIcon(for: status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor(for: status))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(statusColor(for: status).opacity(0.12), in: Capsule())
            .accessibilityLabel(badge)
    }

    private func status(fromDataState dataState: String, coverage: String) -> SummaryPopoverProjection.DataStatus {
        switch dataState {
        case "Stale": .stale
        case "Unavailable", "Absent": .unavailable
        default: coverage == "Partial" ? .partial : .live
        }
    }

    private func statusColor(for status: SummaryPopoverProjection.DataStatus) -> Color {
        switch status {
        case .live: .green
        case .partial: .orange
        case .stale: .yellow
        case .unavailable: .red
        }
    }

    private func statusIcon(for status: SummaryPopoverProjection.DataStatus) -> String {
        switch status {
        case .live: "circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .stale: "clock.fill"
        case .unavailable: "xmark.circle.fill"
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

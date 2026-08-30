import CodingAgentMetricsCore
import SwiftUI

struct TrendsSurfaceProjection: Equatable {
    enum State: Equatable {
        case loading
        case empty
        case unavailable
        case content
    }

    struct Metric: Equatable {
        var title: String
        var aggregateText: String
        var windowAndBucketText: String
        var metadata: String
        var detailText: String
        var sourceText: String
        var limitationText: String?
        var actionText: String?
        var chart: TrendChart?
        var chartStyle: TrendChartView.Style
        var tableControl: AccessibilityNavigation.Control
    }

    var state: State
    var message: String?
    var output: Metric
    var activity: Metric

    static func make(
        snapshot: LightSnapshot?,
        trends: TrendSnapshot?,
        activity: AccessibilityNavigation.ActivityMetric,
        isLoading: Bool
    ) -> TrendsSurfaceProjection {
        let summary = snapshot.map { LightSnapshotPresentation(snapshot: $0) }
        let output = metric(
            title: "Output Throughput",
            aggregateText: summary.map { "\($0.valueText) \($0.unitText)" } ?? "Unavailable",
            chart: trends?.outputThroughput,
            style: .line,
            tableControl: .outputTable
        )
        let selectedTitle = activity == .burn ? "Token Burn" : "Calls"
        let selectedUnit = activity == .burn ? "tokens/min" : "calls/min"
        let activityMetric = metric(
            title: selectedTitle,
            aggregateText: activity == .burn
                ? summary.map { "\($0.burnValueText) \(selectedUnit)" } ?? "Unavailable"
                : summary.map { "\($0.callsValueText) \(selectedUnit)" } ?? "Unavailable",
            chart: activity == .burn ? trends?.tokenBurn : trends?.calls,
            style: activity == .burn ? .burnParts : .calls,
            tableControl: .activityTable
        )

        if isLoading {
            return TrendsSurfaceProjection(state: .loading, message: "Loading trends…", output: output, activity: activityMetric)
        }
        guard trends != nil else {
            return TrendsSurfaceProjection(state: .empty, message: "Trends unavailable", output: output, activity: activityMetric)
        }
        if let reason = output.limitationText ?? activityMetric.limitationText,
           output.chart?.dataState == .unavailable || activityMetric.chart?.dataState == .unavailable {
            return TrendsSurfaceProjection(state: .unavailable, message: reason, output: output, activity: activityMetric)
        }
        return TrendsSurfaceProjection(state: .content, message: nil, output: output, activity: activityMetric)
    }

    private static func metric(
        title: String,
        aggregateText: String,
        chart: TrendChart?,
        style: TrendChartView.Style,
        tableControl: AccessibilityNavigation.Control
    ) -> Metric {
        let presentation = chart.map { TrendPresentation(chart: $0) }
        return Metric(
            title: title,
            aggregateText: aggregateText,
            windowAndBucketText: chart.map { "\($0.windowSeconds / 60)m window · \($0.bucketSeconds)s buckets" } ?? "Window unavailable",
            metadata: presentation.map { "\($0.qualityText) · \($0.dataStateText) · \($0.coverageText)" } ?? "Unavailable · Unavailable · Partial",
            detailText: presentation.map { "\($0.freshnessText) · \($0.sampleCountText)" } ?? "No update · n 0",
            sourceText: presentation.map { "\($0.sourceAuthorityText) · \($0.scopeText) · \($0.definitionVersionText)" } ?? "unavailable · All · unavailable",
            limitationText: presentation?.reasonText,
            actionText: presentation?.actionText,
            chart: chart,
            chartStyle: style,
            tableControl: tableControl
        )
    }

}

struct TrendsSurfaceView: View {
    static let backAccessibilityLabel = "Back to summary"
    static let outputTableAccessibilityLabel = "Output Throughput exact data"
    static let activityTableAccessibilityLabel = "Activity exact data"

    let snapshot: LightSnapshot?
    let trends: TrendSnapshot?
    let isLoading: Bool
    let onBack: () -> Void
    @ObservedObject private var accessibility: AccessibilitySession
    @State private var selectedActivity: AccessibilityNavigation.ActivityMetric
    @FocusState private var focusedControl: AccessibilityNavigation.Control?

    init(
        snapshot: LightSnapshot?,
        trends: TrendSnapshot?,
        accessibility: AccessibilitySession? = nil,
        isLoading: Bool = false,
        onBack: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.trends = trends
        self.isLoading = isLoading
        self.onBack = onBack
        let session = accessibility ?? AccessibilitySession()
        _accessibility = ObservedObject(wrappedValue: session)
        _selectedActivity = State(initialValue: session.navigation.activity)
    }

    var body: some View {
        let projection = TrendsSurfaceProjection.make(
            snapshot: snapshot,
            trends: trends,
            activity: selectedActivity,
            isLoading: isLoading
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Back", action: back)
                    .focused($focusedControl, equals: .back)
                    .accessibilityFocusChrome(focusedControl == .back)
                    .accessibilityLabel(Self.backAccessibilityLabel)
                Spacer()
                Text("Trends").font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch projection.state {
                    case .loading, .empty, .unavailable:
                        Text(projection.message ?? "Trends unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                    case .content:
                        metricCard(projection.output, tableAccessibilityLabel: Self.outputTableAccessibilityLabel)
                        Picker("Activity", selection: $selectedActivity) {
                            Text("Burn").tag(AccessibilityNavigation.ActivityMetric.burn)
                            Text("Calls").tag(AccessibilityNavigation.ActivityMetric.calls)
                        }
                        .pickerStyle(.segmented)
                        .focused($focusedControl, equals: .activityPicker)
                        .accessibilityFocusChrome(focusedControl == .activityPicker)
                        .accessibilityLabel("Activity")
                        metricCard(projection.activity, tableAccessibilityLabel: Self.activityTableAccessibilityLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0)
        }
        .padding(14)
        .frame(minWidth: AppIdentity.popoverWidth, idealWidth: AppIdentity.popoverWidth, maxWidth: AppIdentity.popoverWidth, alignment: .leading)
        .frame(maxHeight: 720)
        .background(.regularMaterial)
        .onAppear { syncFocus() }
        .onChange(of: selectedActivity) { _, activity in accessibility.selectActivity(activity) }
        .onChange(of: accessibility.navigation.focusedControl) { _, _ in syncFocus() }
    }

    private func metricCard(_ metric: TrendsSurfaceProjection.Metric, tableAccessibilityLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(metric.aggregateText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(metric.windowAndBucketText).font(.caption2).foregroundStyle(.secondary)
            statusBadge(metric.metadata)
            Text(metric.detailText).font(.caption2).foregroundStyle(.secondary)
            Text(metric.sourceText).font(.caption2).foregroundStyle(.secondary)
            if let limitation = metric.limitationText {
                Text(limitation).font(.caption2).foregroundStyle(.secondary)
            }
            if let action = metric.actionText {
                Text(action).font(.caption2).foregroundStyle(.tint)
            }
            if let chart = metric.chart {
                TrendChartView(
                    chart: chart,
                    style: metric.chartStyle,
                    isTableFocused: focusedControl == metric.tableControl,
                    onTableFocused: { accessibility.activate(metric.tableControl) }
                )
                .focused($focusedControl, equals: metric.tableControl)
                .accessibilityFocusChrome(focusedControl == metric.tableControl)
                .accessibilityLabel(tableAccessibilityLabel)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
            .accessibilityLabel(text)
    }

    private func back() {
        onBack()
    }

    private func syncFocus() {
        let control = accessibility.focusedControl
        focusedControl = control == .statusItem ? nil : control
    }
}

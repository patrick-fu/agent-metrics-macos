import AppKit
import Charts
import CodingAgentMetricsCore
import SwiftUI

struct TrendChartView: View {
    enum Style { case line, burnParts, calls }

    let chart: TrendChart
    let style: Style
    var isTableFocused: Bool = false
    var onTableFocused: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedBucketStart: Date?
    @State private var tableCursor = AccessibleTrendTableCursor()

    private var presentation: TrendPresentation {
        TrendPresentation(chart: chart, reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                if style == .burnParts {
                    ForEach(chart.partSeries) { part in
                        ForEach(part.buckets) { bucket in
                            if let value = bucket.value {
                                BarMark(x: .value("Time", bucket.start), y: .value("Value", value))
                                    .foregroundStyle(partPatternStyle(part.part))
                                    .annotation(position: .top, spacing: 0) {
                                        if shouldAnnotate(part: part, bucket: bucket) {
                                            Text(part.part.symbol)
                                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                        }
                    }
                } else {
                    let plans = Self.plotPlans(for: chart)
                    ForEach(Array(chart.series.enumerated()), id: \.element.id) { index, series in
                        let plan = plans.first { $0.identityLabel == series.identity.accessibilityLabel }
                        ForEach(series.buckets) { bucket in
                            if let value = bucket.value {
                                mark(value: value, series: series, bucket: bucket, plan: plan)
                            }
                        }
                        if style == .line, let plan, let last = endpointBucket(in: series), let value = last.value, plan.showsEndpointLabel {
                            PointMark(x: .value("Time", last.start), y: .value("Value", value))
                                .foregroundStyle(color(for: series.colorSlot))
                                .symbol(TrendLinePlotPlanning.chartSymbol(plan.shapeName))
                                .annotation(position: .trailing, alignment: .leading, spacing: CGFloat(2 + index * 3)) {
                                    Text(plan.visibleEndpointText)
                                        .font(.system(size: 8, design: .monospaced))
                                        .accessibilityLabel(plan.endpointLabel)
                                        .accessibilityValue(plan.endpointLabel)
                                }
                        }
                    }
                }
                if let selectedBucketStart,
                   let bucket = chart.series.first?.buckets.first(where: { $0.start == selectedBucketStart }) {
                    RuleMark(x: .value("Time", bucket.start))
                        .foregroundStyle(.secondary)
                    PointMark(x: .value("Time", bucket.start), y: .value("Value", 0))
                        .opacity(0)
                        .annotation(position: .top, alignment: .leading) { tooltip(for: bucket.start) }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = value.location.x - geometry[plotFrame].origin.x
                            selectedBucketStart = proxy.value(atX: x, as: Date.self).flatMap(nearestBucket)
                        })
                }
            }
            .frame(height: 130)
            .animation(presentation.allowsContinuousAnimation ? .easeInOut(duration: 0.2) : nil, value: chart)
            legend
            accessibleTable
        }
        .onAppear { tableCursor.clamp(to: chart.table) }
        .onChange(of: chart.table) { _, table in
            tableCursor.clamp(to: table)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trend chart")
    }

    nonisolated static func plotPlans(for chart: TrendChart) -> [TrendLinePlotPlan] {
        TrendLinePlotPlanning.plans(chart: chart)
    }

    @ChartContentBuilder
    private func mark(value: Double, series: TrendSeries, bucket: TrendBucket, plan: TrendLinePlotPlan?) -> some ChartContent {
        switch style {
        case .line:
            LineMark(
                x: .value("Time", bucket.start), y: .value("Value", value),
                series: .value("Model", series.identity.accessibilityLabel)
            )
            .foregroundStyle(color(for: series.colorSlot))
            .lineStyle(StrokeStyle(lineWidth: series.emphasis == .estimated ? 1.5 : 2, dash: dash(from: plan?.dash ?? [])))
            .symbol(TrendLinePlotPlanning.chartSymbol(plan?.shapeName ?? "circle"))
        case .calls:
            BarMark(
                x: .value("Time", bucket.start), y: .value("Value", value)
            )
            .foregroundStyle(color(for: series.colorSlot))
            .opacity(series.emphasis == .normal ? 1 : 0.65)
        case .burnParts:
            BarMark(x: .value("Time", bucket.start), y: .value("Value", value))
                .opacity(0)
        }
    }

    private func nearestBucket(to date: Date) -> Date? {
        chart.series.first?.buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }?.start
    }

    @ViewBuilder
    private func tooltip(for start: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(start, format: .dateTime.hour().minute().second())
            ForEach(chart.series) { series in
                if let count = series.buckets.first(where: { $0.start == start })?.absoluteCount {
                    Text("\(series.title): \(count)")
                }
            }
        }
        .font(.caption2)
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    private var accessibleTable: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("Time").font(.caption2)
                    ForEach(Array(chart.table.columns.enumerated()), id: \.offset) { _, column in
                        Text("\(column.symbol) \(column.title)")
                            .font(.caption2)
                            .accessibilityLabel("\(column.title), \(column.identityLabel), \(column.emphasisText)")
                    }
                }
                ForEach(Array(chart.table.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    GridRow {
                        Text(row.bucketStart, format: .dateTime.hour().minute().second()).font(.caption2)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { columnIndex, cell in
                            let spoken = AccessibleTrendTableCursor(rowIndex: rowIndex, columnIndex: columnIndex)
                                .cellAccessibility(in: chart.table)
                            Text(cell)
                                .font(.caption2)
                                .monospacedDigit()
                                .padding(1)
                                .background(isSelected(row: rowIndex, column: columnIndex) ? Color.primary.opacity(0.12) : Color.clear)
                                .overlay {
                                    if isSelected(row: rowIndex, column: columnIndex) {
                                        Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 1]))
                                    }
                                }
                                .accessibilityLabel(spoken.label)
                                .accessibilityValue(spoken.value)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 80)
        .focusable(true)
        .onTapGesture(perform: onTableFocused)
        .onMoveCommand { direction in
            onTableFocused()
            switch direction {
            case .up: tableCursor.move(rows: -1, columns: 0, in: chart.table)
            case .down: tableCursor.move(rows: 1, columns: 0, in: chart.table)
            case .left: tableCursor.move(rows: 0, columns: -1, in: chart.table)
            case .right: tableCursor.move(rows: 0, columns: 1, in: chart.table)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tableAccessibilityLabel)
        .accessibilityValue(tableCursor.announcement(in: chart.table))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            if style == .burnParts {
                ForEach(presentation.partCues, id: \.title) { cue in
                    Text("\(cue.symbol) \(cue.title) [\(cue.textureName)]")
                        .font(.caption2)
                        .foregroundStyle(partColor(part(for: cue.title)))
                }
            } else {
                ForEach(presentation.seriesCues, id: \.identityLabel) { cue in
                    Text("\(cue.symbol) \(cue.title) [\(cue.identityLabel)] \(cue.text) \(cue.endpoint)")
                        .font(.caption2)
                        .foregroundStyle(color(for: cue.identityLabel == "Other models" ? "other" : cue.identityLabel))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trend legend")
    }

    private func color(for identity: String) -> Color {
        if identity == "other" { return .gray }
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .cyan, .mint]
        return colors[TrendColorPalette.slotIndex(identity, count: colors.count)]
    }

    private func nonColorDash(for series: TrendSeries) -> [CGFloat] {
        switch series.emphasis {
        case .estimated: [4, 3]
        case .partial: [1, 2]
        case .other: [6, 2]
        case .normal: []
        }
    }

    private func partColor(_ part: TrendTokenPart) -> Color {
        switch part {
        case .inputUncached: .blue
        case .cacheRead: .teal
        case .cacheWrite: .cyan
        case .outputVisible: .orange
        case .reasoning: .purple
        }
    }

    private func partPatternStyle(_ part: TrendTokenPart) -> AnyShapeStyle {
        let image = BurnPartPatternRenderer.image(textureName: part.textureName, color: NSColor(partColor(part)))
        return AnyShapeStyle(ImagePaint(image: Image(nsImage: image), scale: 1))
    }

    private func dash(from values: [Int]) -> [CGFloat] {
        values.map { CGFloat($0) }
    }

    private func part(for title: String) -> TrendTokenPart {
        TrendTokenPart.allCases.first { $0.title == title } ?? .inputUncached
    }

    private func shouldAnnotate(part: TrendPartSeries, bucket: TrendBucket) -> Bool {
        guard !reduceMotion else { return false }
        return part.buckets.last(where: { $0.absoluteCount != nil })?.start == bucket.start
    }

    private func endpointBucket(in series: TrendSeries) -> TrendBucket? {
        series.buckets.last { $0.isComplete && $0.value != nil }
    }

    private func isSelected(row: Int, column: Int) -> Bool {
        isTableFocused && tableCursor.rowIndex == row && tableCursor.columnIndex == column
    }

    private var tableAccessibilityLabel: String {
        let columns = chart.table.columns.map { "\($0.symbol) \($0.title) \($0.identityLabel)" }.joined(separator: ", ")
        return "Exact trend values. Quality \(chart.table.qualityText). State \(chart.table.dataStateText). Coverage \(chart.table.coverageText). Columns: \(columns)."
    }
}

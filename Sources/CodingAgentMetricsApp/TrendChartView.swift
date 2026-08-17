import Charts
import CodingAgentMetricsCore
import SwiftUI

struct TrendChartView: View {
    enum Style { case line, burnParts, calls }

    let chart: TrendChart
    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedBucketStart: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                if style == .burnParts {
                    ForEach(chart.partSeries) { part in
                        ForEach(part.buckets) { bucket in
                            if let value = bucket.value {
                                BarMark(x: .value("Time", bucket.start), y: .value("Value", value))
                                    .foregroundStyle(partColor(part.part))
                            }
                        }
                    }
                } else {
                    ForEach(chart.series) { series in
                        ForEach(series.buckets) { bucket in
                            if let value = bucket.value {
                                mark(value: value, series: series, bucket: bucket)
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chart)
            legend
            accessibleTable
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trend chart")
    }

    @ChartContentBuilder
    private func mark(value: Double, series: TrendSeries, bucket: TrendBucket) -> some ChartContent {
        switch style {
        case .line:
            LineMark(
                x: .value("Time", bucket.start), y: .value("Value", value),
                series: .value("Model", series.identity.accessibilityLabel)
            )
            .foregroundStyle(color(for: series.colorSlot))
            .lineStyle(StrokeStyle(lineWidth: series.emphasis == .estimated ? 1.5 : 2, dash: nonColorDash(for: series)))
            .symbol(series.emphasis == .other ? .square : .circle)
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
                    ForEach(Array(chart.table.columnTitles.enumerated()), id: \.offset) { _, title in
                        Text(title).font(.caption2)
                    }
                }
                ForEach(chart.table.rows) { row in
                    GridRow {
                        Text(row.bucketStart, format: .dateTime.hour().minute().second()).font(.caption2)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 80)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Exact trend values")
    }

    private var legend: some View {
        HStack(spacing: 8) {
            if style == .burnParts {
                ForEach(chart.partSeries) { part in
                    Text(part.part.title).font(.caption2).foregroundStyle(partColor(part.part))
                }
            } else {
                ForEach(chart.series) { series in
                    Text("\(series.emphasis == .other ? "◇ " : series.emphasis == .estimated ? "┄ " : series.emphasis == .partial ? "╌ " : "● ")\(series.title) [\(series.identity.accessibilityLabel)]")
                        .font(.caption2)
                        .foregroundStyle(color(for: series.colorSlot))
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
}

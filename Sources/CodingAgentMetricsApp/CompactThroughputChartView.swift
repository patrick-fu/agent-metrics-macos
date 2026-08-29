import CodingAgentMetricsCore
import SwiftUI

/// The summary owns a visual-only chart. Details keeps the full, navigable chart
/// and its exact-value table so the compact surface never duplicates those cues.
struct CompactThroughputChartView: View {
    private struct AxisTick: Identifiable {
        var id: Int
        var label: String
    }

    let chart: TrendChart

    private var renderPlan: CompactThroughputChartRenderPlan {
        CompactThroughputChartRenderPlan.make(chart: chart)
    }

    private var maximum: Double {
        let highest = chart.series.flatMap(\.buckets).compactMap(\.value).max() ?? 0
        return max(60, (highest / 20).rounded(.up) * 20)
    }

    private var axisTicks: [AxisTick] {
        guard let buckets = chart.series.first?.buckets, !buckets.isEmpty else { return [] }
        var previousLabel: String?
        return (0...6).map { tick in
            let index = Int((Double(tick) / 6 * Double(buckets.count - 1)).rounded())
            let label = axisLabel(buckets[index].start)
            defer { previousLabel = label }
            return AxisTick(id: tick, label: previousLabel == label ? "" : label)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Output throughput")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("5s buckets")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            legend
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array((0...4).reversed()), id: \.self) { index in
                        Text(valueLabel(Double(index) / 4 * maximum))
                            .font(.caption2)
                            .foregroundStyle(.primary.opacity(0.62))
                            .frame(height: 35, alignment: .topTrailing)
                    }
                }
                .frame(width: 30)
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                    for series in renderPlan.series {
                        draw(series, in: &context, size: size)
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Output throughput trend")
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: 37)
                ForEach(axisTicks) { tick in
                    Text(tick.label)
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output throughput chart")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(stride(from: 0, to: renderPlan.series.count, by: 2)), id: \.self) { start in
                HStack(spacing: 10) {
                    ForEach(renderPlan.series[start..<min(start + 2, renderPlan.series.count)]) { series in
                        legendItem(series)
                    }
                }
            }
        }
    }

    private func legendItem(_ series: CompactThroughputChartRenderPlan.Series) -> some View {
        HStack(spacing: 3) {
            Canvas { context, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    line,
                    with: .color(color(for: series.colorSlot)),
                    style: StrokeStyle(lineWidth: 2, dash: series.dash.map(CGFloat.init))
                )
            }
            .frame(width: 14, height: 8)
            Text(series.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .accessibilityLabel(series.legendLabel)
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for index in 0...4 {
            let y = size.height * CGFloat(index) / 4
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
        }
        for index in 0...6 {
            let x = size.width * CGFloat(index) / 6
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func draw(_ series: CompactThroughputChartRenderPlan.Series, in context: inout GraphicsContext, size: CGSize) {
        for segment in series.lineSegments where !segment.isEmpty {
            let points = segment.map {
                CGPoint(x: size.width * $0.x, y: size.height * (1 - min(CGFloat($0.value / maximum), 1)))
            }
            if points.count == 1, let point = points.first {
                let marker = markerPath(shape: series.markerShape, at: point)
                context.fill(marker, with: .color(color(for: series.colorSlot)))
                context.stroke(marker, with: .color(color(for: series.colorSlot)), lineWidth: 1.5)
                continue
            }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(color(for: series.colorSlot)),
                style: StrokeStyle(lineWidth: 2.5, dash: series.dash.map(CGFloat.init))
            )
        }
    }

    private func valueLabel(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func color(for identity: String) -> Color {
        switch identity {
        case "gpt-a": return .blue
        case "gpt-b": return .green
        case "gpt-c": return .purple
        case "other-model", "other": return .gray
        default: break
        }
        let colors: [Color] = [.blue, .green, .purple, .gray, .orange, .teal]
        return colors[TrendColorPalette.slotIndex(identity, count: colors.count)]
    }

    private func markerPath(shape: String, at point: CGPoint) -> Path {
        let radius: CGFloat = 3.5
        switch shape {
        case "triangle":
            var path = Path()
            path.move(to: CGPoint(x: point.x, y: point.y - radius))
            path.addLine(to: CGPoint(x: point.x + radius, y: point.y + radius))
            path.addLine(to: CGPoint(x: point.x - radius, y: point.y + radius))
            path.closeSubpath()
            return path
        case "square":
            return Path(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        case "diamond":
            var path = Path()
            path.move(to: CGPoint(x: point.x, y: point.y - radius))
            path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
            path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
            path.addLine(to: CGPoint(x: point.x - radius, y: point.y))
            path.closeSubpath()
            return path
        case "plus", "asterisk":
            var path = Path()
            path.move(to: CGPoint(x: point.x - radius, y: point.y))
            path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - radius))
            path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
            if shape == "asterisk" {
                path.move(to: CGPoint(x: point.x - radius, y: point.y - radius))
                path.addLine(to: CGPoint(x: point.x + radius, y: point.y + radius))
                path.move(to: CGPoint(x: point.x + radius, y: point.y - radius))
                path.addLine(to: CGPoint(x: point.x - radius, y: point.y + radius))
            }
            return path
        case "pentagon":
            var path = Path()
            for index in 0..<5 {
                let angle = CGFloat(index) * (.pi * 2 / 5) - .pi / 2
                let vertex = CGPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius)
                if index == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
            }
            path.closeSubpath()
            return path
        default:
            return Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private func axisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

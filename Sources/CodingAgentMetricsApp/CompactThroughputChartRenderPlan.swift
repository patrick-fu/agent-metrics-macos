import CodingAgentMetricsCore
import Foundation

struct CompactThroughputChartRenderPlan: Equatable {
    struct Point: Equatable {
        var x: Double
        var value: Double
    }

    struct Series: Equatable, Identifiable {
        var identityLabel: String
        var title: String
        var colorSlot: String
        var colorIndex: Int
        var symbol: String
        var dash: [Int]
        var lineSegments: [[Point]]

        var id: String { identityLabel }
        var showsMarker: Bool { lineSegments.contains { $0.count == 1 } }
        var markerShape: String { TrendLinePlotPlanning.shapeName(for: symbol) }
        var legendLabel: String { "\(symbol) \(title)" }
    }

    var series: [Series]

    static func make(chart: TrendChart) -> CompactThroughputChartRenderPlan {
        let cues = Dictionary(
            uniqueKeysWithValues: TrendPresentation(chart: chart).seriesCues.map { ($0.identityLabel, $0) }
        )
        var normalSeriesIndex = 0
        return CompactThroughputChartRenderPlan(series: chart.series.map { series in
            let identity = series.identity.accessibilityLabel
            guard let cue = cues[identity] else {
                preconditionFailure("TrendPresentation must provide a cue for every series")
            }
            let denominator = max(series.buckets.count - 1, 1)
            let segments = TrendLinePlotPlanning.segments(for: series).map { segment in
                segment.points.compactMap { point -> Point? in
                    guard let index = series.buckets.firstIndex(where: { $0.start == point.start }) else { return nil }
                    return Point(x: Double(index) / Double(denominator), value: point.value)
                }
            }
            let isOther = series.role == .other || series.title == "Other"
            let dash: [Int]
            if isOther {
                dash = [8, 3, 2, 3]
            } else {
                switch normalSeriesIndex {
                case 0: dash = []
                case 1: dash = [6, 3]
                case 2: dash = [2, 2]
                default: dash = cue.dash
                }
                normalSeriesIndex += 1
            }
            return Series(
                identityLabel: identity,
                title: series.title,
                colorSlot: series.colorSlot,
                colorIndex: TrendColorPalette.slotIndex(series.colorSlot, count: 6),
                symbol: cue.symbol,
                dash: dash,
                lineSegments: segments
            )
        })
    }
}

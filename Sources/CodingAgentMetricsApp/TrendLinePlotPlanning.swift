import Charts
import CodingAgentMetricsCore

struct TrendLinePlotPlan: Equatable, Sendable {
    var identityLabel: String
    var shapeName: String
    var endpointLabel: String
    var visibleEndpointText: String
    var showsEndpointLabel: Bool
    var dash: [Int]
}

enum TrendLinePlotPlanning {
    static let knownShapeNames = ["circle", "triangle", "square", "diamond", "plus", "asterisk", "pentagon"]

    static func plans(chart: TrendChart, reduceMotion: Bool = false) -> [TrendLinePlotPlan] {
        let presentation = TrendPresentation(chart: chart, reduceMotion: reduceMotion)
        return zip(chart.series, presentation.seriesCues).enumerated().map { index, pair in
            let cue = pair.1
            return TrendLinePlotPlan(
                identityLabel: cue.identityLabel,
                shapeName: shapeName(for: cue.symbol),
                endpointLabel: cue.endpoint,
                visibleEndpointText: visibleText(cue.endpoint),
                showsEndpointLabel: index < 5,
                dash: cue.dash
            )
        }
    }

    static func shapeName(for symbol: String) -> String {
        switch symbol {
        case "▲", "▽": "triangle"
        case "■", "▤", "◇": "square"
        case "◆": "diamond"
        case "✚": "plus"
        case "★": "asterisk"
        case "⬡": "pentagon"
        default: "circle"
        }
    }

    static func chartSymbol(_ shapeName: String) -> BasicChartSymbolShape {
        switch shapeName {
        case "triangle": .triangle
        case "square": .square
        case "diamond": .diamond
        case "plus": .plus
        case "asterisk": .asterisk
        case "pentagon": .pentagon
        default: .circle
        }
    }

    static func visibleText(_ raw: String) -> String {
        raw.count <= 8 ? raw : String(raw.prefix(7)) + "..."
    }
}

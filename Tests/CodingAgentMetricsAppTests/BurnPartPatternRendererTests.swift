import AppKit
import Testing
@testable import CodingAgentMetricsApp

struct BurnPartPatternRendererTests {
    @Test func hatchPatternsAreNotFlatColorAndSolidIsUniform() {
        let color = NSColor.black
        for name in ["grid", "stripes", "triangle", "dots"] {
            let image = BurnPartPatternRenderer.image(textureName: name, color: color)
            #expect(BurnPartPatternRenderer.distinctColorCount(in: image) > 1)
        }
        let solid = BurnPartPatternRenderer.image(textureName: "solid", color: color)
        #expect(BurnPartPatternRenderer.distinctColorCount(in: solid) == 1)
    }
}

import AppKit
import Testing
@testable import CodingAgentMetricsApp

@Suite
struct PanelPlacementTests {
    @Test
    func keepsFullWidthInsideRightVisibleEdge() {
        let placement = PanelPlacement.resizedFrame(
            from: NSRect(x: 900, y: 300, width: 440, height: 300),
            contentSize: NSSize(width: 440, height: 300),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(placement == NSRect(x: 560, y: 300, width: 440, height: 300))
    }

    @Test
    func keepsFullWidthInsideLeftVisibleEdge() {
        let placement = PanelPlacement.resizedFrame(
            from: NSRect(x: -80, y: 300, width: 440, height: 300),
            contentSize: NSSize(width: 440, height: 300),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(placement == NSRect(x: 0, y: 300, width: 440, height: 300))
    }

    @Test
    func respectsNonzeroVisibleFrameOriginWhenClampingRightEdge() {
        let placement = PanelPlacement.resizedFrame(
            from: NSRect(x: 1_400, y: 300, width: 440, height: 300),
            contentSize: NSSize(width: 440, height: 300),
            visibleFrame: NSRect(x: 500, y: 100, width: 1_000, height: 700)
        )

        #expect(placement == NSRect(x: 1_060, y: 300, width: 440, height: 300))
    }

    @Test
    func respectsNegativeScreenCoordinatesWhenClampingLeftEdge() {
        let placement = PanelPlacement.resizedFrame(
            from: NSRect(x: -1_400, y: 300, width: 440, height: 300),
            contentSize: NSSize(width: 440, height: 300),
            visibleFrame: NSRect(x: -1_280, y: 0, width: 1_280, height: 800)
        )

        #expect(placement == NSRect(x: -1_280, y: 300, width: 440, height: 300))
    }

    @Test
    func fillsNarrowVisibleFrameAtItsOrigin() {
        let placement = PanelPlacement.resizedFrame(
            from: NSRect(x: 800, y: 300, width: 440, height: 300),
            contentSize: NSSize(width: 440, height: 300),
            visibleFrame: NSRect(x: -200, y: 0, width: 320, height: 800)
        )

        #expect(placement == NSRect(x: -200, y: 300, width: 320, height: 300))
    }
}

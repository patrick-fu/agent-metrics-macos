import AppKit
import Testing
@testable import CodingAgentMetricsApp

struct KeyablePanelTests {
    @Test @MainActor
    func panelPlacementKeepsTopAnchorWithinVisibleFrameAcrossRepeatedContentResizes() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let topAnchor = 850.0
        let panel = KeyablePanel(
            contentRect: NSRect(x: 620, y: topAnchor - 240, width: 240, height: 240),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        for height in [320.0, 260.0, 420.0, 280.0] {
            let next = PanelPlacement.resizedFrame(
                from: panel.frame,
                contentSize: NSSize(width: 240, height: height),
                visibleFrame: visibleFrame
            )
            panel.setFrame(next, display: false)

            #expect(abs(panel.frame.maxY - topAnchor) < 0.001)
            #expect(panel.frame.minY >= visibleFrame.minY)
            #expect(panel.frame.maxY <= visibleFrame.maxY)
        }
    }

    @Test @MainActor
    func nonactivatingKeyablePanelCanBecomeKeyAndTakeFirstResponder() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        view.focusRingType = .exterior
        panel.contentView = view

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false)

        panel.makeKeyAndOrderFront(nil)
        #expect(panel.makeFirstResponder(view))
        #expect(panel.firstResponder === view)
        panel.orderOut(nil)
    }
}

import AppKit
import Testing
@testable import CodingAgentMetricsApp

struct KeyablePanelTests {
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

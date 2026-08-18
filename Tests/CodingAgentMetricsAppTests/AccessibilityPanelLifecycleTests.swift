import AppKit
import Testing
@testable import CodingAgentMetricsApp

struct AccessibilityPanelLifecycleTests {
    @Test @MainActor
    func resignKeyDuringModalKeepsPanelAndFinishRestoresKeyAndSaveFocus() {
        _ = NSApplication.shared
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)

        let session = AccessibilitySession()
        session.openPanel()
        session.activate(.settings)
        session.activate(.diagnosticsSave)
        let confirmation = session.navigation
        var dismissed = false
        var modal = true
        let lifecycle = AccessibilityPanelLifecycle(
            panel: panel,
            accessibility: session,
            hasModalWindow: { modal },
            isMenuTracking: { false },
            onDismiss: { dismissed = true }
        )

        lifecycle.handleResignKey()
        #expect(dismissed == false)
        #expect(panel.isVisible)
        #expect(session.navigation == confirmation)

        modal = false
        lifecycle.onExternalModalFinished()

        #expect(panel.isVisible)
        #expect(panel.isKeyWindow || panel.canBecomeKey)
        #expect(panel.firstResponder === view || panel.makeFirstResponder(view))
        #expect(session.surface == .settings)
        #expect(session.focusedControl == .diagnosticsSave)
        #expect(dismissed == false)
        panel.orderOut(nil)
    }

    @Test @MainActor
    func resignKeyDuringMenuTrackingDoesNotDismiss() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.orderFront(nil)
        let session = AccessibilitySession()
        session.openPanel()
        var dismissed = false
        let lifecycle = AccessibilityPanelLifecycle(
            panel: panel,
            accessibility: session,
            hasModalWindow: { false },
            isMenuTracking: { true },
            onDismiss: { dismissed = true }
        )
        lifecycle.handleResignKey()
        #expect(dismissed == false)
        #expect(session.surface == .summary)
        panel.orderOut(nil)
    }
}

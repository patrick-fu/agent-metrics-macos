import AppKit
import Combine
import Testing
@testable import CodingAgentMetricsApp

struct AccessibilityPanelLifecycleTests {
    enum ExternalDismissBlocker: CaseIterable, Sendable {
        case confirmation
        case modalWindow
        case menuTracking
    }

    @Test(arguments: ExternalDismissBlocker.allCases) @MainActor
    func externalDismissIsIgnoredWhilePanelInteractionIsProtected(
        blocker: ExternalDismissBlocker
    ) {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let session = AccessibilitySession()
        session.openPanel()
        var hasModalWindow = false
        var isMenuTracking = false
        switch blocker {
        case .confirmation:
            session.activate(.settings)
            session.activate(.diagnosticsCopy)
        case .modalWindow:
            hasModalWindow = true
        case .menuTracking:
            isMenuTracking = true
        }
        var dismissed = false
        let lifecycle = AccessibilityPanelLifecycle(
            panel: panel,
            accessibility: session,
            hasModalWindow: { hasModalWindow },
            isMenuTracking: { isMenuTracking },
            onDismiss: { dismissed = true }
        )

        lifecycle.handleExternalDismissRequest()

        #expect(dismissed == false)
    }

    @Test(arguments: [
        AccessibilityNavigation.Control.diagnosticsCopy,
        .resetReview,
    ]) @MainActor
    func resignKeyDuringConfirmationKeepsParentPanelEvenBeforeModalWindowIsRegistered(
        trigger: AccessibilityNavigation.Control
    ) {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let session = AccessibilitySession()
        session.openPanel()
        session.activate(.settings)
        session.activate(trigger)
        var dismissed = false
        let lifecycle = AccessibilityPanelLifecycle(
            panel: panel,
            accessibility: session,
            hasModalWindow: { false },
            isMenuTracking: { false },
            onDismiss: { dismissed = true }
        )

        lifecycle.handleResignKey()

        #expect(session.isModalConfirmation)
        #expect(dismissed == false)
    }

    @Test @MainActor
    func synchronousDismissalConsumerIsNotReentered() {
        let session = AccessibilitySession()
        var dismissNotifications = 0
        var observesDismissals = false
        let observer = session.$navigation.sink { navigation in
            guard observesDismissals, navigation.surface == .dismissed else { return }
            dismissNotifications += 1
            if dismissNotifications == 1 {
                session.dismissToStatusItem()
            }
        }

        session.openPanel()
        observesDismissals = true
        session.dismissToStatusItem()

        #expect(dismissNotifications == 1)
        #expect(session.surface == .dismissed)
        withExtendedLifetime(observer) {}
    }

    @Test @MainActor
    func externalDismissClosesPanelWhenNoInteractionIsProtected() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let session = AccessibilitySession()
        session.openPanel()
        var dismissed = false
        let lifecycle = AccessibilityPanelLifecycle(
            panel: panel,
            accessibility: session,
            hasModalWindow: { false },
            isMenuTracking: { false },
            onDismiss: { dismissed = true }
        )

        lifecycle.handleExternalDismissRequest()

        #expect(dismissed)
    }

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

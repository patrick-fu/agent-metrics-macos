import AppKit

@MainActor
final class AccessibilityPanelLifecycle {
    private let panel: KeyablePanel
    private let accessibility: AccessibilitySession
    private let hasModalWindow: () -> Bool
    private let isMenuTracking: () -> Bool
    private let onDismiss: () -> Void

    init(
        panel: KeyablePanel,
        accessibility: AccessibilitySession,
        hasModalWindow: @escaping () -> Bool,
        isMenuTracking: @escaping () -> Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.panel = panel
        self.accessibility = accessibility
        self.hasModalWindow = hasModalWindow
        self.isMenuTracking = isMenuTracking
        self.onDismiss = onDismiss
    }

    func handleResignKey() {
        handleExternalDismissRequest()
    }

    func handleExternalDismissRequest() {
        if accessibility.isModalConfirmation || hasModalWindow() || isMenuTracking() { return }
        onDismiss()
    }

    func onExternalModalFinished() {
        if case .diagnosticsConfirmation(.save) = accessibility.surface {
            accessibility.escape()
        }
        accessibility.focus(.diagnosticsSave)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }
}

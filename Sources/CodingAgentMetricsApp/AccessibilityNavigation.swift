struct AccessibilityNavigation: Equatable, Sendable {
    enum Surface: Equatable, Sendable {
        case dismissed
        case summary
        case trends
        case settings
        case diagnosticsConfirmation(DiagnosticsAction)
        case resetConfirmation
    }

    enum Control: Equatable, Sendable {
        case statusItem
        case agentFilter
        case modelFilter
        case windowSelector
        case qualityDisclosure
        case performanceEnable
        case performanceRange
        case activityPicker
        case viewTrends
        case settings
        case back
        case launchAtLogin
        case aggregateWindow
        case displayCadence
        case enhancedTelemetry
        case diagnosticsPreview
        case diagnosticsCopy
        case diagnosticsSave
        case diagnosticsPrepare
        case resetReview
        case checkForUpdates
        case confirmationConfirm
        case confirmationCancel
        case outputTable
        case activityTable
    }

    enum DiagnosticsAction: Equatable, Sendable {
        case copy
        case save
        case preparePublicIssue
    }

    enum ActivityMetric: String, Equatable, Hashable, Sendable {
        case burn = "Burn"
        case calls = "Calls"
    }

    private(set) var surface: Surface
    private(set) var focusedControl: Control
    private(set) var activity: ActivityMetric
    private(set) var showsPerformanceEnable: Bool

    var isPanelVisible: Bool { surface != .dismissed }

    static let closed = AccessibilityNavigation(
        surface: .dismissed,
        focusedControl: .statusItem,
        activity: .burn,
        showsPerformanceEnable: true
    )

    mutating func setShowsPerformanceEnable(_ visible: Bool) {
        showsPerformanceEnable = visible
        if !visible, focusedControl == .performanceEnable {
            focusedControl = controls(for: surface).first ?? focusedControl
        }
    }

    mutating func openPanel() {
        guard surface == .dismissed else { return }
        surface = .summary
        focusedControl = .agentFilter
    }

    mutating func escape() {
        switch surface {
        case .dismissed:
            focusedControl = .statusItem
        case .summary:
            surface = .dismissed
            focusedControl = .statusItem
        case .trends:
            surface = .summary
            focusedControl = .viewTrends
        case .settings:
            surface = .summary
            focusedControl = .settings
        case .diagnosticsConfirmation(let action):
            surface = .settings
            focusedControl = trigger(for: action)
        case .resetConfirmation:
            surface = .settings
            focusedControl = .resetReview
        }
    }

    mutating func activateFocusedControl() {
        activate(focusedControl)
    }

    mutating func selectActivity(_ activity: ActivityMetric) {
        self.activity = activity
        if surface == .trends {
            focusedControl = .activityPicker
        }
    }

    mutating func focus(_ control: Control) {
        if controls(for: surface).contains(control) {
            focusedControl = control
        }
    }

    mutating func activate(_ control: Control) {
        switch (surface, control) {
        case (.summary, .viewTrends):
            surface = .trends
            focusedControl = .back
        case (.summary, .settings):
            surface = .settings
            focusedControl = .back
        case (.trends, .back), (.settings, .back):
            escape()
        case (.settings, .diagnosticsCopy):
            surface = .diagnosticsConfirmation(.copy)
            focusedControl = .confirmationCancel
        case (.settings, .diagnosticsSave):
            surface = .diagnosticsConfirmation(.save)
            focusedControl = .confirmationCancel
        case (.settings, .diagnosticsPrepare):
            surface = .diagnosticsConfirmation(.preparePublicIssue)
            focusedControl = .confirmationCancel
        case (.settings, .resetReview):
            surface = .resetConfirmation
            focusedControl = .confirmationCancel
        case (.diagnosticsConfirmation, .confirmationCancel), (.resetConfirmation, .confirmationCancel):
            escape()
        case (.diagnosticsConfirmation, .confirmationConfirm):
            surface = .settings
            focusedControl = currentDiagnosticsAction.map(trigger(for:)) ?? .diagnosticsCopy
        case (.resetConfirmation, .confirmationConfirm):
            surface = .settings
            focusedControl = .resetReview
        default:
            if controls(for: surface).contains(control) {
                focusedControl = control
            }
        }
    }

    mutating func moveFocus(forward: Bool) {
        let order = controls(for: surface)
        guard let current = order.firstIndex(of: focusedControl) else {
            focusedControl = forward ? order.first ?? focusedControl : order.last ?? focusedControl
            return
        }
        let next = forward ? current + 1 : current - 1
        guard order.indices.contains(next) else { return }
        focusedControl = order[next]
    }

    private var currentDiagnosticsAction: DiagnosticsAction? {
        if case .diagnosticsConfirmation(let action) = surface { return action }
        return nil
    }

    private func trigger(for action: DiagnosticsAction) -> Control {
        switch action {
        case .copy: .diagnosticsCopy
        case .save: .diagnosticsSave
        case .preparePublicIssue: .diagnosticsPrepare
        }
    }

    private func controls(for surface: Surface) -> [Control] {
        switch surface {
        case .dismissed:
            return [.statusItem]
        case .summary:
            var summary: [Control] = [.agentFilter, .modelFilter, .windowSelector, .settings]
            if showsPerformanceEnable {
                summary.append(.performanceEnable)
            }
            return summary + [.qualityDisclosure, .viewTrends]
        case .trends:
            return [.back, .outputTable, .activityPicker, .activityTable]
        case .settings:
            return [
                .back,
                .launchAtLogin,
                .aggregateWindow,
                .displayCadence,
                .enhancedTelemetry,
                .diagnosticsPreview,
                .diagnosticsCopy,
                .diagnosticsSave,
                .diagnosticsPrepare,
                .resetReview,
                .checkForUpdates,
            ]
        case .diagnosticsConfirmation, .resetConfirmation:
            return [.confirmationCancel, .confirmationConfirm]
        }
    }
}

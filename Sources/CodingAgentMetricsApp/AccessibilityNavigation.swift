struct DiagnosticsTextAvailability: Equatable, Sendable {
    var preview: Bool
    var publicIssue: Bool

    static let none = DiagnosticsTextAvailability(preview: false, publicIssue: false)

    static func make(previewText: String?, publicIssueText: String?) -> Self {
        Self(preview: previewText != nil, publicIssue: publicIssueText != nil)
    }
}

struct AccessibilityNavigation: Equatable, Sendable {
    enum Surface: Equatable, Sendable {
        case dismissed
        case summary
        case trends
        case settings
        case dataDiagnostics
        case aboutUpdates
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
        case openDataDiagnostics
        case openAboutUpdates
        case aboutCheckForUpdates
        case diagnosticsPreviewText
        case diagnosticsPublicIssueText
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
    private(set) var diagnosticsText = DiagnosticsTextAvailability.none

    var isPanelVisible: Bool { surface != .dismissed }

    static let closed = AccessibilityNavigation(
        surface: .dismissed,
        focusedControl: .statusItem,
        activity: .burn,
        showsPerformanceEnable: true,
        diagnosticsText: .none
    )

    mutating func setShowsPerformanceEnable(_ visible: Bool) {
        showsPerformanceEnable = visible
        if !visible, focusedControl == .performanceEnable {
            focusedControl = controls(for: surface).first ?? focusedControl
        }
    }

    mutating func setDiagnosticsTextAvailability(_ availability: DiagnosticsTextAvailability) {
        diagnosticsText = availability
        let order = controls(for: surface)
        if !order.contains(focusedControl) {
            focusedControl = order.first ?? focusedControl
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
        case .dataDiagnostics:
            surface = .settings
            focusedControl = .openDataDiagnostics
        case .aboutUpdates:
            surface = .settings
            focusedControl = .openAboutUpdates
        case .diagnosticsConfirmation(let action):
            surface = .dataDiagnostics
            focusedControl = trigger(for: action)
        case .resetConfirmation:
            surface = .dataDiagnostics
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
        case (.settings, .openDataDiagnostics):
            surface = .dataDiagnostics
            focusedControl = .back
        case (.settings, .openAboutUpdates):
            surface = .aboutUpdates
            focusedControl = .back
        case (.trends, .back), (.settings, .back), (.dataDiagnostics, .back), (.aboutUpdates, .back):
            escape()
        case (.dataDiagnostics, .diagnosticsCopy):
            surface = .diagnosticsConfirmation(.copy)
            focusedControl = .confirmationCancel
        case (.dataDiagnostics, .diagnosticsSave):
            surface = .diagnosticsConfirmation(.save)
            focusedControl = .confirmationCancel
        case (.dataDiagnostics, .diagnosticsPrepare):
            surface = .diagnosticsConfirmation(.preparePublicIssue)
            focusedControl = .confirmationCancel
        case (.dataDiagnostics, .resetReview):
            surface = .resetConfirmation
            focusedControl = .confirmationCancel
        case (.diagnosticsConfirmation, .confirmationCancel), (.resetConfirmation, .confirmationCancel):
            escape()
        case (.diagnosticsConfirmation, .confirmationConfirm):
            surface = .dataDiagnostics
            focusedControl = currentDiagnosticsAction.map(trigger(for:)) ?? .diagnosticsCopy
        case (.resetConfirmation, .confirmationConfirm):
            surface = .dataDiagnostics
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
        let next = forward
            ? (current + 1) % order.count
            : (current - 1 + order.count) % order.count
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
            var summary: [Control] = [.windowSelector, .settings, .agentFilter, .modelFilter]
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
                .checkForUpdates,
                .openDataDiagnostics,
                .openAboutUpdates,
            ]
        case .dataDiagnostics:
            var order: [Control] = [.back, .diagnosticsPreview]
            if diagnosticsText.preview {
                order.append(.diagnosticsPreviewText)
            }
            order += [.diagnosticsCopy, .diagnosticsSave, .diagnosticsPrepare]
            if diagnosticsText.publicIssue {
                order.append(.diagnosticsPublicIssueText)
            }
            order.append(.resetReview)
            return order
        case .aboutUpdates:
            return [.back, .aboutCheckForUpdates]
        case .diagnosticsConfirmation, .resetConfirmation:
            return [.confirmationCancel, .confirmationConfirm]
        }
    }
}

import Testing
@testable import CodingAgentMetricsApp

struct AccessibilityNavigationTests {
    @Test func openingThePanelFocusesTheAgentFilterAndEscapeDismissesToTheStatusItem() {
        var navigation = AccessibilityNavigation.closed

        #expect(navigation.surface == .dismissed)
        #expect(navigation.focusedControl == .statusItem)
        #expect(navigation.isPanelVisible == false)

        navigation.openPanel()

        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .agentFilter)
        #expect(navigation.isPanelVisible)

        navigation.escape()

        #expect(navigation.surface == .dismissed)
        #expect(navigation.focusedControl == .statusItem)
        #expect(navigation.isPanelVisible == false)

        navigation.escape()

        #expect(navigation.surface == .dismissed)
        #expect(navigation.focusedControl == .statusItem)
    }

    @Test func escapeFromTrendsReturnsFocusToViewTrends() {
        var navigation = openedSummary()
        navigation.activate(.viewTrends)

        #expect(navigation.surface == .trends)
        #expect(navigation.focusedControl == .back)

        navigation.escape()

        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .viewTrends)
    }

    @Test func escapeFromSettingsReturnsFocusToSettings() {
        var navigation = openedSummary()
        navigation.activate(.settings)

        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .back)

        navigation.escape()

        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .settings)
    }

    @Test func settingsOpensDataDiagnosticsAndAboutUpdatesThenEscapeRestoresTheNavigationRow() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        navigation.activate(.openDataDiagnostics)

        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .back)

        navigation.escape()
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .openDataDiagnostics)

        navigation.activate(.openAboutUpdates)
        #expect(navigation.surface == .aboutUpdates)
        #expect(navigation.focusedControl == .back)

        navigation.escape()
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .openAboutUpdates)

        navigation.escape()
        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .settings)
    }

    @Test func escapeFromDiagnosticAndResetConfirmationsReturnsToTheDataTriggerWithoutRepeatingWork() {
        var navigation = openedDataDiagnostics()

        navigation.activate(.diagnosticsCopy)
        #expect(navigation.surface == .diagnosticsConfirmation(.copy))
        #expect(navigation.focusedControl == .confirmationCancel)
        navigation.escape()
        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .diagnosticsCopy)

        navigation.activate(.diagnosticsSave)
        navigation.escape()
        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .diagnosticsSave)

        navigation.activate(.diagnosticsPrepare)
        navigation.escape()
        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .diagnosticsPrepare)

        navigation.activate(.resetReview)
        #expect(navigation.surface == .resetConfirmation)
        navigation.escape()
        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .resetReview)

        navigation.escape()
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .openDataDiagnostics)
        navigation.escape()
        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .settings)
        navigation.escape()
        navigation.escape()
        #expect(navigation.surface == .dismissed)
        #expect(navigation.focusedControl == .statusItem)
    }

    @Test func confirmingAModalReturnsFocusToTheDataTrigger() {
        var navigation = openedDataDiagnostics()
        navigation.activate(.diagnosticsCopy)
        navigation.activate(.confirmationConfirm)
        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .diagnosticsCopy)

        navigation.activate(.resetReview)
        navigation.activate(.confirmationConfirm)
        #expect(navigation.surface == .dataDiagnostics)
        #expect(navigation.focusedControl == .resetReview)
    }

    @Test func summaryTabOrderFollowsTheVisualReadingFlowAndWrapsInBothDirections() {
        var navigation = openedSummary()
        #expect(navigation.focusedControl == .agentFilter)

        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .modelFilter)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .performanceEnable)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .qualityDisclosure)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .viewTrends)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .windowSelector)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .settings)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .agentFilter)

        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .settings)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .windowSelector)
        navigation.focus(.windowSelector)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .viewTrends)
    }

    @Test func summaryOmitsPerformanceEnableWhenTelemetryMetricsAreAvailable() {
        var navigation = openedSummary()
        navigation.setShowsPerformanceEnable(false)
        let order: [AccessibilityNavigation.Control] = [
            .agentFilter, .modelFilter, .qualityDisclosure, .viewTrends, .windowSelector, .settings,
        ]
        #expect(navigation.focusedControl == .agentFilter)
        for control in order.dropFirst() {
            navigation.moveFocus(forward: true)
            #expect(navigation.focusedControl == control)
        }
        #expect(navigation.focusedControl != .performanceEnable)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .agentFilter)
    }

    @Test func tabFromTheLastSettingsControlWrapsToTheBackControl() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        navigation.focus(.openAboutUpdates)

        navigation.moveFocus(forward: true)

        #expect(navigation.focusedControl == .back)
    }

    @Test func settingsTabOrderReachesLoginTelemetryUpdatesAndDeepNavigationRows() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        #expect(navigation.focusedControl == .back)

        let expected: [AccessibilityNavigation.Control] = [
            .launchAtLogin,
            .aggregateWindow,
            .displayCadence,
            .enhancedTelemetry,
            .checkForUpdates,
            .openDataDiagnostics,
            .openAboutUpdates,
        ]
        for control in expected {
            navigation.moveFocus(forward: true)
            #expect(navigation.focusedControl == control)
        }
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .openDataDiagnostics)
    }

    @Test func dataDiagnosticsTabOrderSkipsMissingDiagnosticTextControls() {
        var navigation = openedDataDiagnostics()
        #expect(navigation.focusedControl == .back)
        #expect(DiagnosticsTextAvailability.make(previewText: nil, publicIssueText: nil) == .none)

        let expected: [AccessibilityNavigation.Control] = [
            .diagnosticsPreview,
            .diagnosticsCopy,
            .diagnosticsSave,
            .diagnosticsPrepare,
            .resetReview,
        ]
        for control in expected {
            navigation.moveFocus(forward: true)
            #expect(navigation.focusedControl == control)
            #expect(navigation.focusedControl != .diagnosticsPreviewText)
            #expect(navigation.focusedControl != .diagnosticsPublicIssueText)
        }
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .back)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .resetReview)
    }

    @Test func dataDiagnosticsTabOrderInsertsExistingTextControlsAndWraps() {
        var navigation = openedDataDiagnostics()
        navigation.setDiagnosticsTextAvailability(
            DiagnosticsTextAvailability.make(previewText: "{}", publicIssueText: nil)
        )

        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .diagnosticsPreview)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .diagnosticsPreviewText)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .diagnosticsCopy)

        navigation.setDiagnosticsTextAvailability(
            DiagnosticsTextAvailability.make(previewText: "{}", publicIssueText: "issue")
        )
        navigation.focus(.diagnosticsPrepare)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .diagnosticsPublicIssueText)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .resetReview)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .back)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .resetReview)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .diagnosticsPublicIssueText)
    }

    @Test func hidingDiagnosticTextMovesFocusOffTheRemovedControl() {
        var navigation = openedDataDiagnostics()
        navigation.setDiagnosticsTextAvailability(
            DiagnosticsTextAvailability.make(previewText: "{}", publicIssueText: "issue")
        )
        navigation.focus(.diagnosticsPreviewText)
        navigation.setDiagnosticsTextAvailability(.none)
        #expect(navigation.focusedControl != .diagnosticsPreviewText)
        #expect(navigation.focusedControl != .diagnosticsPublicIssueText)

        let remaining: [AccessibilityNavigation.Control] = [
            .back, .diagnosticsPreview, .diagnosticsCopy, .diagnosticsSave, .diagnosticsPrepare, .resetReview,
        ]
        #expect(remaining.contains(navigation.focusedControl))
        navigation.focus(.diagnosticsPublicIssueText)
        #expect(navigation.focusedControl != .diagnosticsPublicIssueText)
    }

    @Test func aboutUpdatesTabOrderReachesCheckForUpdatesAndWraps() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        navigation.activate(.openAboutUpdates)
        #expect(navigation.focusedControl == .back)

        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .aboutCheckForUpdates)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .back)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .aboutCheckForUpdates)
    }

    @Test func confirmationAndTrendsTabOrdersWrapInBothDirections() {
        var navigation = openedDataDiagnostics()
        navigation.activate(.diagnosticsCopy)
        #expect(navigation.focusedControl == .confirmationCancel)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .confirmationConfirm)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .confirmationCancel)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .confirmationConfirm)

        navigation.escape()
        navigation.escape()
        navigation.escape()
        navigation.activate(.viewTrends)
        navigation.focus(.activityTable)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .back)
        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .activityTable)
    }

    @Test func trendsTabOrderReachesBackAndExactTables() {
        var navigation = openedSummary()
        navigation.activate(.viewTrends)
        #expect(navigation.focusedControl == .back)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .outputTable)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .activityPicker)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .activityTable)
    }

    @Test func activityPickerCanSwitchToCallsAndFocusTheActivityTable() {
        var navigation = openedSummary()
        #expect(navigation.activity == .burn)
        navigation.activate(.viewTrends)
        navigation.activate(.activityPicker)
        #expect(navigation.focusedControl == .activityPicker)
        navigation.selectActivity(.calls)
        #expect(navigation.activity == .calls)
        #expect(navigation.focusedControl == .activityPicker)
        navigation.activate(.activityTable)
        #expect(navigation.surface == .trends)
        #expect(navigation.activity == .calls)
        #expect(navigation.focusedControl == .activityTable)
    }

    @Test func reopeningThePanelRestoresTheFirstSummaryControl() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        navigation.escape()
        navigation.escape()
        navigation.openPanel()
        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .agentFilter)
    }

    @Test func openingAnAlreadyVisiblePanelDoesNotResetFocus() {
        var navigation = openedSummary()
        navigation.moveFocus(forward: true)
        navigation.openPanel()
        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .modelFilter)
    }

    private func openedSummary() -> AccessibilityNavigation {
        var navigation = AccessibilityNavigation.closed
        navigation.openPanel()
        return navigation
    }

    private func openedDataDiagnostics() -> AccessibilityNavigation {
        var navigation = openedSummary()
        navigation.activate(.settings)
        navigation.activate(.openDataDiagnostics)
        return navigation
    }
}

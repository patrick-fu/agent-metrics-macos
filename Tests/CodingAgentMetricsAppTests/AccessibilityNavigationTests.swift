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

    @Test func escapeFromDiagnosticAndResetConfirmationsReturnsToTheTriggerWithoutRepeatingWork() {
        var navigation = openedSummary()
        navigation.activate(.settings)

        navigation.activate(.diagnosticsCopy)
        #expect(navigation.surface == .diagnosticsConfirmation(.copy))
        #expect(navigation.focusedControl == .confirmationCancel)
        navigation.escape()
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .diagnosticsCopy)

        navigation.activate(.diagnosticsSave)
        navigation.escape()
        #expect(navigation.focusedControl == .diagnosticsSave)

        navigation.activate(.diagnosticsPrepare)
        navigation.escape()
        #expect(navigation.focusedControl == .diagnosticsPrepare)

        navigation.activate(.resetReview)
        #expect(navigation.surface == .resetConfirmation)
        navigation.escape()
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .resetReview)

        navigation.escape()
        #expect(navigation.surface == .summary)
        #expect(navigation.focusedControl == .settings)
        navigation.escape()
        navigation.escape()
        #expect(navigation.surface == .dismissed)
        #expect(navigation.focusedControl == .statusItem)
    }

    @Test func confirmingAModalReturnsFocusToTheTrigger() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        navigation.activate(.diagnosticsCopy)
        navigation.activate(.confirmationConfirm)
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .diagnosticsCopy)

        navigation.activate(.resetReview)
        navigation.activate(.confirmationConfirm)
        #expect(navigation.surface == .settings)
        #expect(navigation.focusedControl == .resetReview)
    }

    @Test func summaryTabOrderReachesFiltersRangeTrendsAndSettings() {
        var navigation = openedSummary()
        #expect(navigation.focusedControl == .agentFilter)

        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .modelFilter)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .performanceRange)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .activityPicker)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .viewTrends)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .settings)
        navigation.moveFocus(forward: true)
        #expect(navigation.focusedControl == .settings)

        navigation.moveFocus(forward: false)
        #expect(navigation.focusedControl == .viewTrends)
    }

    @Test func settingsTabOrderReachesLoginTelemetryDiagnosticsResetAndUpdate() {
        var navigation = openedSummary()
        navigation.activate(.settings)
        #expect(navigation.focusedControl == .back)

        let expected: [AccessibilityNavigation.Control] = [
            .launchAtLogin,
            .enhancedTelemetry,
            .diagnosticsPreview,
            .diagnosticsCopy,
            .diagnosticsSave,
            .diagnosticsPrepare,
            .resetReview,
            .checkForUpdates,
        ]
        for control in expected {
            navigation.moveFocus(forward: true)
            #expect(navigation.focusedControl == control)
        }
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
        navigation.activate(.activityPicker)
        #expect(navigation.focusedControl == .activityPicker)
        navigation.selectActivity(.calls)
        #expect(navigation.activity == .calls)
        #expect(navigation.focusedControl == .activityPicker)

        navigation.activate(.viewTrends)
        navigation.selectActivity(.calls)
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
}

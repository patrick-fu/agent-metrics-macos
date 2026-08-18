import Testing
@testable import CodingAgentMetricsApp

struct AccessibilityKeyRoutingTests {
    @Test func panelEscapeAndTabAreHandledOnlyForThePanelWindow() {
        let routing = AccessibilityKeyRouting()
        #expect(routing.decision(for: .panelEscape) == .handleEscape)
        #expect(routing.decision(for: .panelTab) == .handleTab(shift: false))
        #expect(routing.decision(for: .panelShiftTab) == .handleTab(shift: true))
        #expect(routing.decision(for: .foreignEscape) == .ignore)
        #expect(routing.decision(for: .foreignTab) == .ignore)
    }

    @Test func menuTrackingDoesNotSwallowEscapeOrTab() {
        var routing = AccessibilityKeyRouting()
        routing.menuDidBeginTracking()
        #expect(routing.decision(for: .panelEscape) == .ignore)
        #expect(routing.decision(for: .panelTab) == .ignore)
        routing.menuDidEndTracking()
        #expect(routing.decision(for: .panelEscape) == .handleEscape)
        #expect(routing.decision(for: .panelTab) == .handleTab(shift: false))
    }

    @Test func modalOrSavePanelEscapeIsNotSwallowed() {
        var routing = AccessibilityKeyRouting()
        #expect(routing.decision(for: .modalEscape) == .ignore)
        #expect(routing.decision(for: .modalTab) == .ignore)
        #expect(routing.decision(for: .savePanelEscape) == .ignore)
        routing.menuDidBeginTracking()
        #expect(routing.decision(for: .modalEscape) == .ignore)
    }
}

private extension AccessibilityKeyEvent {
    static let panelEscape = AccessibilityKeyEvent(
        isFromPanel: true, hasModalWindow: false, isEscape: true, isTab: false, shiftPressed: false
    )
    static let panelTab = AccessibilityKeyEvent(
        isFromPanel: true, hasModalWindow: false, isEscape: false, isTab: true, shiftPressed: false
    )
    static let panelShiftTab = AccessibilityKeyEvent(
        isFromPanel: true, hasModalWindow: false, isEscape: false, isTab: true, shiftPressed: true
    )
    static let foreignEscape = AccessibilityKeyEvent(
        isFromPanel: false, hasModalWindow: false, isEscape: true, isTab: false, shiftPressed: false
    )
    static let foreignTab = AccessibilityKeyEvent(
        isFromPanel: false, hasModalWindow: false, isEscape: false, isTab: true, shiftPressed: false
    )
    static let modalEscape = AccessibilityKeyEvent(
        isFromPanel: true, hasModalWindow: true, isEscape: true, isTab: false, shiftPressed: false
    )
    static let modalTab = AccessibilityKeyEvent(
        isFromPanel: true, hasModalWindow: true, isEscape: false, isTab: true, shiftPressed: false
    )
    static let savePanelEscape = AccessibilityKeyEvent(
        isFromPanel: false, hasModalWindow: true, isEscape: true, isTab: false, shiftPressed: false
    )
}

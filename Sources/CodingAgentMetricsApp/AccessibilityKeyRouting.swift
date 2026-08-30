import AppKit

struct AccessibilityKeyEvent: Equatable, Sendable {
    var isFromPanel: Bool
    var hasModalWindow: Bool
    var isEscape: Bool
    var isTab: Bool
    var shiftPressed: Bool

    init(
        isFromPanel: Bool,
        hasModalWindow: Bool,
        isModalConfirmation: Bool = false,
        isEscape: Bool,
        isTab: Bool,
        shiftPressed: Bool
    ) {
        self.isFromPanel = isFromPanel
        self.hasModalWindow = hasModalWindow || isModalConfirmation
        self.isEscape = isEscape
        self.isTab = isTab
        self.shiftPressed = shiftPressed
    }

    init(event: NSEvent, panel: NSWindow, hasModalWindow: Bool, isModalConfirmation: Bool = false) {
        self.init(
            isFromPanel: event.window === panel,
            hasModalWindow: hasModalWindow,
            isModalConfirmation: isModalConfirmation,
            isEscape: event.keyCode == 53,
            isTab: event.keyCode == 48,
            shiftPressed: event.modifierFlags.contains(.shift)
        )
    }
}

struct AccessibilityKeyRouting: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case handleEscape
        case handleTab(shift: Bool)
        case ignore
    }

    private(set) var isMenuTracking = false

    mutating func menuDidBeginTracking() {
        isMenuTracking = true
    }

    mutating func menuDidEndTracking() {
        isMenuTracking = false
    }

    func decision(for event: AccessibilityKeyEvent) -> Decision {
        guard event.isFromPanel, !event.hasModalWindow, !isMenuTracking else {
            return .ignore
        }
        if event.isEscape { return .handleEscape }
        if event.isTab { return .handleTab(shift: event.shiftPressed) }
        return .ignore
    }
}

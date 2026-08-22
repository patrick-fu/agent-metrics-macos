import Combine
import CodingAgentMetricsCore
import SwiftUI

@MainActor
final class AccessibilitySession: ObservableObject {
    @Published private(set) var navigation = AccessibilityNavigation.closed
    private var isDismissingToStatusItem = false

    var focusedControl: AccessibilityNavigation.Control { navigation.focusedControl }
    var surface: AccessibilityNavigation.Surface { navigation.surface }
    var isPanelVisible: Bool { navigation.isPanelVisible }
    var isModalConfirmation: Bool {
        switch navigation.surface {
        case .diagnosticsConfirmation, .resetConfirmation: true
        default: false
        }
    }

    func openPanel() {
        navigation.openPanel()
    }

    func dismissToStatusItem() {
        guard !isDismissingToStatusItem, navigation.surface != .dismissed else { return }
        isDismissingToStatusItem = true
        defer { isDismissingToStatusItem = false }
        navigation = .closed
    }

    func escape() {
        navigation.escape()
    }

    func activate(_ control: AccessibilityNavigation.Control) {
        navigation.activate(control)
    }

    func activateFocusedControl() {
        navigation.activateFocusedControl()
    }

    func moveFocus(forward: Bool) {
        navigation.moveFocus(forward: forward)
    }

    func selectActivity(_ activity: AccessibilityNavigation.ActivityMetric) {
        navigation.selectActivity(activity)
    }

    func focus(_ control: AccessibilityNavigation.Control) {
        navigation.focus(control)
    }

    func setShowsPerformanceEnable(_ visible: Bool) {
        navigation.setShowsPerformanceEnable(visible)
    }

    var activityBinding: Binding<AccessibilityNavigation.ActivityMetric> {
        Binding(
            get: { self.navigation.activity },
            set: { self.selectActivity($0) }
        )
    }
}

struct ActivitySurfaceProjection: Equatable {
    var selected: AccessibilityNavigation.ActivityMetric
    var chartStyle: TrendChartView.Style
    var table: AccessibleTrendTable

    static func make(navigation: AccessibilityNavigation, trends: TrendSnapshot?) -> ActivitySurfaceProjection {
        switch navigation.activity {
        case .calls:
            return ActivitySurfaceProjection(
                selected: .calls,
                chartStyle: .calls,
                table: trends?.calls.table ?? AccessibleTrendTable(columnTitles: ["Calls"], rows: [])
            )
        case .burn:
            return ActivitySurfaceProjection(
                selected: .burn,
                chartStyle: .burnParts,
                table: trends?.tokenBurn.table ?? AccessibleTrendTable(columnTitles: [], rows: [])
            )
        }
    }
}

struct AccessibilityFocusChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(2)
            .background(isFocused ? Color.primary.opacity(0.08) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: isFocused ? 2 : 0, dash: isFocused ? [4, 2] : []))
                    .foregroundStyle(isFocused ? Color.accentColor : Color.clear)
            }
            .overlay(alignment: .leading) {
                if isFocused {
                    Rectangle()
                        .frame(width: 2)
                        .foregroundStyle(Color.primary)
                        .padding(.vertical, 2)
                }
            }
    }
}

extension View {
    func accessibilityFocusChrome(_ isFocused: Bool) -> some View {
        modifier(AccessibilityFocusChrome(isFocused: isFocused))
    }
}

import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct DisplayPreferencesRelaunchTests {
    @Test @MainActor
    func relaunchRestoresSavedWindowAndCadenceInsteadOfResettingSummaryDefaults() {
        let suite = "cam-display-relaunch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = DisplayPreferencesStore(defaults: defaults)
        store.window = .tenMinutes
        store.cadence = .sixtySeconds

        let relaunchedStore = DisplayPreferencesStore(defaults: UserDefaults(suiteName: suite)!)
        let preferences = DisplayPreferencesController(store: relaunchedStore)
        #expect(preferences.window == .tenMinutes)
        #expect(preferences.cadence == .sixtySeconds)

        let view = SummaryPopoverView(
            snapshot: nil,
            lifecycleServices: inertLifecycleServices(),
            preferences: preferences
        )
        _ = view.body
        #expect(preferences.window == .tenMinutes)
        #expect(preferences.cadence == .sixtySeconds)
        #expect(preferences.window.menuLabel == "10m")
        #expect(Int(preferences.cadence.seconds) == 60)
    }
}

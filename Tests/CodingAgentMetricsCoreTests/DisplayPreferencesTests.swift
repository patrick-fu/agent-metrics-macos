import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct DisplayPreferencesTests {
    @Test func missingKeysUseLegacyThirtySecondCadenceAndThreeMinuteWindow() {
        let defaults = UserDefaults(suiteName: "cam-display-\(UUID().uuidString)")!
        let store = DisplayPreferencesStore(defaults: defaults)
        #expect(store.cadence == .thirtySeconds)
        #expect(store.window == .threeMinutes)
        #expect(store.cadence.seconds == 30)
        #expect(store.window.seconds == 180)
    }

    @Test func persistedCadenceAndWindowReloadAndRejectUnknownValues() {
        let suite = "cam-display-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = DisplayPreferencesStore(defaults: defaults)
        store.cadence = .sixtySeconds
        store.window = .tenMinutes

        let reloaded = DisplayPreferencesStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.cadence == .sixtySeconds)
        #expect(reloaded.window == .tenMinutes)

        defaults.set(7, forKey: DisplayPreferencesStore.cadenceKey)
        defaults.set(90, forKey: DisplayPreferencesStore.windowKey)
        #expect(DisplayPreferencesStore(defaults: defaults).cadence == .thirtySeconds)
        #expect(DisplayPreferencesStore(defaults: defaults).window == .threeMinutes)
    }
}

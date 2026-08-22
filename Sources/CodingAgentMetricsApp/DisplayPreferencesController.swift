import CodingAgentMetricsCore
import Foundation

@MainActor
final class DisplayPreferencesController: ObservableObject {
    @Published var window: OutputThroughputWindow {
        didSet { store.window = window }
    }
    @Published var cadence: DisplayCadence {
        didSet { store.cadence = cadence }
    }

    private let store: DisplayPreferencesStore

    init(store: DisplayPreferencesStore = DisplayPreferencesStore()) {
        self.store = store
        window = store.window
        cadence = store.cadence
    }
}

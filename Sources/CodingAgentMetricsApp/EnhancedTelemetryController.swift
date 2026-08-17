import CodingAgentMetricsCore
import Foundation
import Observation

@MainActor
@Observable
final class EnhancedTelemetryController {
    static let defaultsKey = "enhancedTelemetryEnabled"

    private let runtime: TelemetryRuntime?
    private let defaults: UserDefaults
    private(set) var isEnabled = false
    private(set) var failureMessage: String?

    let endpoint = OTLPReceiverConfiguration().endpoint.absoluteString

    init(runtime: TelemetryRuntime?, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        self.defaults = defaults
        let requested = defaults.object(forKey: Self.defaultsKey) as? Bool ?? false
        guard requested else { return }
        setEnabled(true, persists: false)
    }

    func setEnabled(_ enabled: Bool) {
        setEnabled(enabled, persists: true)
    }

    private func setEnabled(_ enabled: Bool, persists: Bool) {
        guard let runtime else {
            isEnabled = false
            failureMessage = "Telemetry runtime is unavailable."
            if persists { defaults.set(false, forKey: Self.defaultsKey) }
            return
        }
        do {
            try runtime.setEnhancedTelemetryEnabled(enabled)
            isEnabled = enabled
            failureMessage = nil
            if persists { defaults.set(enabled, forKey: Self.defaultsKey) }
        } catch {
            // A failed bind must never leave the preference or UI claiming opt-in.
            isEnabled = false
            failureMessage = runtime.receiverFailureMessage ?? String(describing: error)
            defaults.set(false, forKey: Self.defaultsKey)
        }
    }
}

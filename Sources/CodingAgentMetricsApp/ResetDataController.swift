import Foundation
import Observation
import CodingAgentMetricsCore

@MainActor
@Observable
final class ResetDataController {
    enum Phase: Equatable {
        case idle
        case confirmationRequired
        case resetting
        case completed
        case completedCleanupPending
        case failed(String)
    }

    static let scope = "Reset deletes all app-owned telemetry: observations, facts, rollups, cursors, watermarks, source state, opaque identities, diagnostics, runtime snapshots, migration backups, and app-managed export copies. Codex and Claude source logs are not deleted. Existing external user-saved files cannot be deleted by the app. Non-telemetry settings are preserved. Uninstalling the app alone does not delete the telemetry store."

    private let reset: (() throws -> TelemetryResetResult)?
    private(set) var phase: Phase = .idle

    var scope: String { Self.scope }
    var isAvailable: Bool { reset != nil }
    var isConfirmationPresented: Bool { phase == .confirmationRequired }

    init(reset: (() throws -> TelemetryResetResult)? = nil) {
        self.reset = reset
    }

    func requestReset() {
        guard reset != nil, phase != .resetting else { return }
        phase = .confirmationRequired
    }

    func cancelReset() {
        guard phase == .confirmationRequired else { return }
        phase = .idle
    }

    func confirmReset() {
        guard phase == .confirmationRequired, let reset else { return }
        phase = .resetting
        do {
            let result = try reset()
            phase = result.cleanupState == .complete ? .completed : .completedCleanupPending
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

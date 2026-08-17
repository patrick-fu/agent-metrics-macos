import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct ResetDataControllerTests {
    @Test @MainActor
    func resetRequiresScopeReviewThenASeparateDestructiveConfirmation() {
        var resetCount = 0
        let controller = ResetDataController(reset: {
            resetCount += 1
            return TelemetryResetResult(cleanupState: .complete)
        })

        #expect(controller.phase == .idle)
        controller.requestReset()
        #expect(controller.phase == .confirmationRequired)
        #expect(resetCount == 0)
        #expect(controller.scope.contains("app-owned telemetry"))
        #expect(controller.scope.contains("Codex and Claude source logs are not deleted"))
        #expect(controller.scope.contains("external user-saved files cannot be deleted"))
        #expect(controller.scope.contains("settings are preserved"))

        controller.cancelReset()
        #expect(controller.phase == .idle)
        controller.requestReset()
        controller.confirmReset()

        #expect(controller.phase == .completed)
        #expect(resetCount == 1)
        controller.confirmReset()
        #expect(resetCount == 1)
    }

    @Test @MainActor
    func committedResetWithDeferredCleanupIsNotReportedAsFailure() {
        let controller = ResetDataController(reset: {
            TelemetryResetResult(cleanupState: .pending)
        })

        controller.requestReset()
        controller.confirmReset()

        #expect(controller.phase == .completedCleanupPending)
    }
}

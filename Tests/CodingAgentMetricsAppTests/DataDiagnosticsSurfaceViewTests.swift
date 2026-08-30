import Foundation
import Testing
@testable import CodingAgentMetricsApp

struct DataDiagnosticsSurfaceViewTests {
    @Test
    func projectionMakesTheLocalFirstBoundaryAndPublicIssueReviewExplicit() {
        let projection = DataDiagnosticsSurfaceProjection.make()

        #expect(projection.privacySummary == "Diagnostics stay on this Mac until you explicitly copy or save them. Nothing is uploaded automatically.")
        #expect(projection.publicIssueReviewSummary == "Prepare text for review, then paste it into a public issue yourself. Nothing is submitted or uploaded.")
        #expect(projection.diagnosticActions.map(\.title) == ["Copy Diagnostics…", "Save Diagnostics…", "Prepare Public Issue…"])
    }

    @Test
    func resetInteractionRequiresScopeReviewBeforeDestructiveConfirmation() {
        var state = DataDiagnosticsInteractionState.idle

        #expect(!state.canConfirmReset)
        state.reviewResetScope()
        #expect(state == .reviewingResetScope)
        #expect(!state.canConfirmReset)
        state.continueToResetConfirmation()
        #expect(state == .resetConfirmation)
        #expect(state.canConfirmReset)

        state.cancelReset()
        #expect(state == .idle)
        #expect(!state.canConfirmReset)
    }

    @Test @MainActor
    func viewConstructsWithoutInvokingDiagnosticOrResetCollaborators() {
        var generated = 0
        var copied = 0
        var saved = 0
        var reset = 0
        var clearedDiagnostics = 0
        let diagnostics = DiagnosticActionController(
            generate: {
                generated += 1
                return Data("{}".utf8)
            },
            copy: { _ in copied += 1 },
            userSelectedSave: { _ in
                saved += 1
                return true
            }
        )
        let resetData = ResetDataController(reset: {
            reset += 1
            return .init(cleanupState: .complete)
        })

        let view = DataDiagnosticsSurfaceView(
            diagnostics: diagnostics,
            resetData: resetData,
            onResetCompleted: { clearedDiagnostics += 1 }
        )

        _ = view.body
        #expect(generated == 0)
        #expect(copied == 0)
        #expect(saved == 0)
        #expect(reset == 0)
        #expect(clearedDiagnostics == 0)
    }

    @Test @MainActor
    func applyingControllerTextAvailabilityInsertsAndRemovesDiagnosticTextControls() {
        let session = AccessibilitySession()
        session.openPanel()
        session.activate(.settings)
        session.activate(.openDataDiagnostics)
        let diagnostics = DiagnosticActionController(
            generate: { Data(#"{"schema":"diagnostic-v1"}"#.utf8) },
            copy: { _ in },
            userSelectedSave: { _ in true }
        )

        session.applyDiagnosticsTextAvailability(from: diagnostics)
        session.focus(.diagnosticsPreview)
        session.moveFocus(forward: true)
        #expect(session.focusedControl == .diagnosticsCopy)

        diagnostics.preview()
        session.applyDiagnosticsTextAvailability(from: diagnostics)
        session.focus(.diagnosticsPreview)
        session.moveFocus(forward: true)
        #expect(session.focusedControl == .diagnosticsPreviewText)

        diagnostics.requestPreparePublicIssue()
        diagnostics.confirmPreparePublicIssue()
        session.applyDiagnosticsTextAvailability(from: diagnostics)
        session.focus(.diagnosticsPrepare)
        session.moveFocus(forward: true)
        #expect(session.focusedControl == .diagnosticsPublicIssueText)

        diagnostics.clearEphemeralState()
        session.applyDiagnosticsTextAvailability(from: diagnostics)
        session.focus(.diagnosticsPreview)
        session.moveFocus(forward: true)
        #expect(session.focusedControl == .diagnosticsCopy)
    }

    @Test
    func accessibilityIdentifiersAreStableForKeyboardReachableDiagnosticText() {
        #expect(DataDiagnosticsSurfaceProjection.AccessibilityID.preview == "data-diagnostics-preview")
        #expect(DataDiagnosticsSurfaceProjection.AccessibilityID.publicIssueText == "data-diagnostics-public-issue")
        #expect(DataDiagnosticsSurfaceProjection.AccessibilityID.resetReview == "data-diagnostics-reset-review")
    }
}

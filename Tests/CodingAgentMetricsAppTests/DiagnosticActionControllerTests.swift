import Foundation
import Testing
@testable import CodingAgentMetricsApp

struct DiagnosticActionControllerTests {
    @Test @MainActor
    func previewIsMemoryOnlyAndDoesNotCrossAnySideEffectBoundary() {
        var generationCount = 0
        var copied = [String]()
        var saved = [Data]()
        let controller = DiagnosticActionController(
            generate: {
                generationCount += 1
                return Data(#"{"schema":"diagnostic-v1"}"#.utf8)
            },
            copy: { copied.append($0) },
            userSelectedSave: {
                saved.append($0)
                return true
            }
        )

        controller.preview()

        #expect(controller.previewText == #"{"schema":"diagnostic-v1"}"#)
        #expect(controller.outcome == .previewed)
        #expect(controller.pendingConfirmation == nil)
        #expect(generationCount == 1)
        #expect(copied.isEmpty)
        #expect(saved.isEmpty)
        #expect(controller.preparedPublicIssueText == nil)
    }

    @Test @MainActor
    func copySaveAndPrepareRequireDistinctOneTimeConfirmations() {
        var copied = [String]()
        var saved = [Data]()
        let controller = DiagnosticActionController(
            generate: { Data(#"{"schema":"diagnostic-v1"}"#.utf8) },
            copy: { copied.append($0) },
            userSelectedSave: {
                saved.append($0)
                return true
            }
        )

        controller.requestCopy()
        #expect(controller.pendingConfirmation == .copy)
        controller.confirmSave()
        #expect(copied.isEmpty)
        #expect(saved.isEmpty)
        controller.confirmCopy()
        controller.confirmCopy()
        #expect(copied == [#"{"schema":"diagnostic-v1"}"#])
        #expect(controller.outcome == .copied)

        controller.requestSave()
        #expect(controller.pendingConfirmation == .save)
        controller.confirmPreparePublicIssue()
        #expect(saved.isEmpty)
        controller.confirmSave()
        controller.confirmSave()
        #expect(saved == [Data(#"{"schema":"diagnostic-v1"}"#.utf8)])
        #expect(controller.outcome == .saved)

        controller.requestPreparePublicIssue()
        #expect(controller.pendingConfirmation == .preparePublicIssue)
        controller.confirmCopy()
        #expect(copied.count == 1)
        controller.confirmPreparePublicIssue()
        controller.confirmPreparePublicIssue()
        #expect(controller.outcome == .publicIssuePrepared)
        #expect(controller.preparedPublicIssueText == """
        ## Agent Metrics diagnostics

        Review the privacy-safe diagnostic payload below, then paste this text into a public issue yourself. Nothing was submitted or uploaded.

        ```json
        {"schema":"diagnostic-v1"}
        ```
        """)
        #expect(copied.count == 1)
        #expect(saved.count == 1)
        #expect(controller.pendingConfirmation == nil)
    }

    @Test @MainActor
    func confirmationCopyIsActionSpecificAndSaveCancellationCreatesNoFileClaim() {
        let controller = DiagnosticActionController(
            generate: { Data("{}".utf8) },
            copy: { _ in },
            userSelectedSave: { _ in false }
        )

        #expect(Set(DiagnosticActionController.Confirmation.allCases.map(\.title)).count == 3)
        #expect(Set(DiagnosticActionController.Confirmation.allCases.map(\.confirmLabel)).count == 3)

        controller.requestSave()
        controller.confirmSave()

        #expect(controller.outcome == .saveCancelled)
        #expect(controller.pendingConfirmation == nil)
    }

    @Test @MainActor
    func clearingEphemeralStateRestoresIdlePreviewIssueAndPendingConfirmation() {
        let controller = DiagnosticActionController(
            generate: { Data(#"{"schema":"diagnostic-v1"}"#.utf8) },
            copy: { _ in },
            userSelectedSave: { _ in true }
        )

        controller.preview()
        controller.requestPreparePublicIssue()
        controller.confirmPreparePublicIssue()
        controller.requestCopy()
        #expect(controller.previewText != nil)
        #expect(controller.preparedPublicIssueText != nil)
        #expect(controller.pendingConfirmation == .copy)
        #expect(controller.outcome == .publicIssuePrepared)

        controller.clearEphemeralState()

        #expect(controller.previewText == nil)
        #expect(controller.preparedPublicIssueText == nil)
        #expect(controller.pendingConfirmation == nil)
        #expect(controller.outcome == .idle)
    }

    @Test @MainActor
    func cancelAndFailedActionsLeaveEphemeralDiagnosticsInPlace() {
        let controller = DiagnosticActionController(
            generate: { Data(#"{"schema":"diagnostic-v1"}"#.utf8) },
            copy: { _ in throw DiagnosticActionError.pasteboardWriteFailed },
            userSelectedSave: { _ in false }
        )

        controller.preview()
        let preview = controller.previewText
        controller.requestCopy()
        controller.cancel(.copy)
        #expect(controller.previewText == preview)
        #expect(controller.outcome == .previewed)

        controller.requestCopy()
        controller.confirmCopy()
        #expect(controller.outcome == .failed(String(describing: DiagnosticActionError.pasteboardWriteFailed)))
        #expect(controller.previewText == preview)

        controller.requestSave()
        controller.confirmSave()
        #expect(controller.outcome == .saveCancelled)
        #expect(controller.previewText == preview)
        #expect(controller.preparedPublicIssueText == nil)
    }
}

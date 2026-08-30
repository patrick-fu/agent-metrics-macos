import Foundation
import Observation

enum DiagnosticActionError: LocalizedError {
    case snapshotUnavailable
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable: "A diagnostic snapshot is not available yet."
        case .pasteboardWriteFailed: "The diagnostic preview could not be copied."
        }
    }
}

@MainActor
@Observable
final class DiagnosticActionController {
    enum Confirmation: String, CaseIterable, Equatable {
        case copy
        case save
        case preparePublicIssue

        var title: String {
            switch self {
            case .copy: "Copy privacy-safe diagnostics?"
            case .save: "Save privacy-safe diagnostics?"
            case .preparePublicIssue: "Prepare text for a public issue?"
            }
        }

        var confirmLabel: String {
            switch self {
            case .copy: "Copy Diagnostics"
            case .save: "Choose Location and Save"
            case .preparePublicIssue: "Prepare Public Issue Text"
            }
        }

        var message: String {
            switch self {
            case .copy:
                "Copies this preview to the clipboard once. Nothing is uploaded."
            case .save:
                "After confirmation, you choose an external save location. The app keeps no managed copy."
            case .preparePublicIssue:
                "Creates text you can review and paste yourself. The app does not submit, upload, or open an issue."
            }
        }
    }

    enum Outcome: Equatable {
        case idle
        case previewed
        case copied
        case saved
        case saveCancelled
        case publicIssuePrepared
        case failed(String)
    }

    private let generate: () throws -> Data
    private let copy: (String) throws -> Void
    private let userSelectedSave: (Data) throws -> Bool

    private(set) var pendingConfirmation: Confirmation?
    private(set) var previewText: String?
    private(set) var preparedPublicIssueText: String?
    private(set) var outcome: Outcome = .idle
    var onExternalModalFinished: (() -> Void)?

    init(
        generate: @escaping () throws -> Data,
        copy: @escaping (String) throws -> Void,
        userSelectedSave: @escaping (Data) throws -> Bool
    ) {
        self.generate = generate
        self.copy = copy
        self.userSelectedSave = userSelectedSave
    }

    func preview() {
        do {
            previewText = String(decoding: try generate(), as: UTF8.self)
            outcome = .previewed
        } catch {
            outcome = .failed(String(describing: error))
        }
    }

    func requestCopy() {
        pendingConfirmation = .copy
    }

    func requestSave() {
        pendingConfirmation = .save
    }

    func requestPreparePublicIssue() {
        pendingConfirmation = .preparePublicIssue
    }

    func cancel(_ confirmation: Confirmation) {
        guard pendingConfirmation == confirmation else { return }
        pendingConfirmation = nil
    }

    func clearEphemeralState() {
        pendingConfirmation = nil
        previewText = nil
        preparedPublicIssueText = nil
        outcome = .idle
    }

    func confirmCopy() {
        guard consume(.copy) else { return }
        do {
            let text = String(decoding: try generate(), as: UTF8.self)
            try copy(text)
            outcome = .copied
        } catch {
            outcome = .failed(String(describing: error))
        }
    }

    func confirmSave() {
        guard consume(.save) else { return }
        do {
            outcome = try userSelectedSave(generate()) ? .saved : .saveCancelled
        } catch {
            outcome = .failed(String(describing: error))
        }
        onExternalModalFinished?()
    }

    func confirmPreparePublicIssue() {
        guard consume(.preparePublicIssue) else { return }
        do {
            let diagnostic = String(decoding: try generate(), as: UTF8.self)
            preparedPublicIssueText = """
            ## Agent Metrics diagnostics

            Review the privacy-safe diagnostic payload below, then paste this text into a public issue yourself. Nothing was submitted or uploaded.

            ```json
            \(diagnostic)
            ```
            """
            outcome = .publicIssuePrepared
        } catch {
            outcome = .failed(String(describing: error))
        }
    }

    private func consume(_ confirmation: Confirmation) -> Bool {
        guard pendingConfirmation == confirmation else { return false }
        pendingConfirmation = nil
        return true
    }
}

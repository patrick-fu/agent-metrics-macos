import SwiftUI

struct DataDiagnosticsSurfaceProjection: Equatable {
    struct DiagnosticAction: Equatable {
        let title: String
        let accessibilityIdentifier: String
    }

    enum AccessibilityID {
        static let preview = "data-diagnostics-preview"
        static let publicIssueText = "data-diagnostics-public-issue"
        static let resetReview = "data-diagnostics-reset-review"
    }

    let privacySummary: String
    let publicIssueReviewSummary: String
    let diagnosticActions: [DiagnosticAction]

    static func make() -> Self {
        Self(
            privacySummary: "Diagnostics stay on this Mac until you explicitly copy or save them. Nothing is uploaded automatically.",
            publicIssueReviewSummary: "Prepare text for review, then paste it into a public issue yourself. Nothing is submitted or uploaded.",
            diagnosticActions: [
                .init(title: "Copy Diagnostics…", accessibilityIdentifier: "data-diagnostics-copy"),
                .init(title: "Save Diagnostics…", accessibilityIdentifier: "data-diagnostics-save"),
                .init(title: "Prepare Public Issue…", accessibilityIdentifier: "data-diagnostics-prepare-public-issue"),
            ]
        )
    }
}

enum DataDiagnosticsInteractionState: Equatable {
    case idle
    case reviewingResetScope
    case resetConfirmation

    var canConfirmReset: Bool { self == .resetConfirmation }

    mutating func reviewResetScope() {
        guard self == .idle else { return }
        self = .reviewingResetScope
    }

    mutating func continueToResetConfirmation() {
        guard self == .reviewingResetScope else { return }
        self = .resetConfirmation
    }

    mutating func cancelReset() {
        self = .idle
    }
}

struct DataDiagnosticsSurfaceView: View {
    let diagnostics: DiagnosticActionController
    let resetData: ResetDataController
    let onResetCompleted: () -> Void
    @ObservedObject private var accessibility: AccessibilitySession
    @FocusState private var focusedControl: AccessibilityNavigation.Control?

    @State private var resetInteraction = DataDiagnosticsInteractionState.idle

    init(
        diagnostics: DiagnosticActionController,
        resetData: ResetDataController,
        accessibility: AccessibilitySession? = nil,
        onResetCompleted: @escaping () -> Void = {}
    ) {
        self.diagnostics = diagnostics
        self.resetData = resetData
        self.onResetCompleted = onResetCompleted
        _accessibility = ObservedObject(wrappedValue: accessibility ?? AccessibilitySession())
    }

    var body: some View {
        @Bindable var diagnosticActions = diagnostics
        let projection = DataDiagnosticsSurfaceProjection.make()

        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Privacy-Safe Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(projection.privacySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Preview Diagnostics") {
                        accessibility.activate(.diagnosticsPreview)
                        diagnosticActions.preview()
                    }
                    .focused($focusedControl, equals: .diagnosticsPreview)
                    .accessibilityFocusChrome(focusedControl == .diagnosticsPreview)
                    .accessibilityIdentifier("data-diagnostics-preview-button")
                    .accessibilityHint("Builds an allowlisted diagnostic preview in memory without writing a file.")

                    if let preview = diagnosticActions.previewText {
                        diagnosticText(
                            preview,
                            identifier: DataDiagnosticsSurfaceProjection.AccessibilityID.preview,
                            control: .diagnosticsPreviewText
                        )
                    }

                    HStack {
                        Button(projection.diagnosticActions[0].title) {
                            diagnosticActions.requestCopy()
                            accessibility.activate(.diagnosticsCopy)
                        }
                        .focused($focusedControl, equals: .diagnosticsCopy)
                        .accessibilityFocusChrome(focusedControl == .diagnosticsCopy)
                        .accessibilityIdentifier(projection.diagnosticActions[0].accessibilityIdentifier)
                        .confirmationDialog(
                            DiagnosticActionController.Confirmation.copy.title,
                            isPresented: diagnosticConfirmationBinding(.copy),
                            titleVisibility: .visible
                        ) {
                            Button(DiagnosticActionController.Confirmation.copy.confirmLabel) {
                                diagnosticActions.confirmCopy()
                                accessibility.activate(.confirmationConfirm)
                            }
                            Button("Cancel", role: .cancel) {
                                diagnosticActions.cancel(.copy)
                                accessibility.escape()
                            }
                        } message: {
                            Text(DiagnosticActionController.Confirmation.copy.message)
                        }

                        Button(projection.diagnosticActions[1].title) {
                            diagnosticActions.requestSave()
                            accessibility.activate(.diagnosticsSave)
                        }
                        .focused($focusedControl, equals: .diagnosticsSave)
                        .accessibilityFocusChrome(focusedControl == .diagnosticsSave)
                        .accessibilityIdentifier(projection.diagnosticActions[1].accessibilityIdentifier)
                        .confirmationDialog(
                            DiagnosticActionController.Confirmation.save.title,
                            isPresented: diagnosticConfirmationBinding(.save),
                            titleVisibility: .visible
                        ) {
                            Button(DiagnosticActionController.Confirmation.save.confirmLabel) {
                                diagnosticActions.confirmSave()
                                accessibility.activate(.confirmationConfirm)
                            }
                            Button("Cancel", role: .cancel) {
                                diagnosticActions.cancel(.save)
                                accessibility.escape()
                            }
                        } message: {
                            Text(DiagnosticActionController.Confirmation.save.message)
                        }
                    }

                    Button(projection.diagnosticActions[2].title) {
                        diagnosticActions.requestPreparePublicIssue()
                        accessibility.activate(.diagnosticsPrepare)
                    }
                    .focused($focusedControl, equals: .diagnosticsPrepare)
                    .accessibilityFocusChrome(focusedControl == .diagnosticsPrepare)
                    .accessibilityIdentifier(projection.diagnosticActions[2].accessibilityIdentifier)
                    .confirmationDialog(
                        DiagnosticActionController.Confirmation.preparePublicIssue.title,
                        isPresented: diagnosticConfirmationBinding(.preparePublicIssue),
                        titleVisibility: .visible
                    ) {
                        Button(DiagnosticActionController.Confirmation.preparePublicIssue.confirmLabel) {
                            diagnosticActions.confirmPreparePublicIssue()
                            accessibility.activate(.confirmationConfirm)
                        }
                        Button("Cancel", role: .cancel) {
                            diagnosticActions.cancel(.preparePublicIssue)
                            accessibility.escape()
                        }
                    } message: {
                        Text(DiagnosticActionController.Confirmation.preparePublicIssue.message)
                    }

                    if let issueText = diagnosticActions.preparedPublicIssueText {
                        Text(projection.publicIssueReviewSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        diagnosticText(
                            issueText,
                            identifier: DataDiagnosticsSurfaceProjection.AccessibilityID.publicIssueText,
                            control: .diagnosticsPublicIssueText
                        )
                    }

                    diagnosticOutcomeText(diagnosticActions.outcome)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Reset Data") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Deletes this app's telemetry and managed copies. Source logs and external user-saved files stay untouched; settings are preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Review Reset Scope…", role: .destructive) {
                        resetInteraction.reviewResetScope()
                        accessibility.activate(.resetReview)
                    }
                    .focused($focusedControl, equals: .resetReview)
                    .accessibilityFocusChrome(focusedControl == .resetReview)
                    .accessibilityIdentifier(DataDiagnosticsSurfaceProjection.AccessibilityID.resetReview)
                    .accessibilityHint("Reviews the complete deletion scope before a separate destructive confirmation.")
                    .disabled(!resetData.isAvailable || resetData.phase == .resetting)
                    .alert(
                        "Review reset scope",
                        isPresented: resetReviewBinding,
                        actions: {
                            Button("Continue") {
                                resetInteraction.continueToResetConfirmation()
                            }
                            Button("Cancel", role: .cancel) {
                                resetInteraction.cancelReset()
                                if accessibility.surface == .resetConfirmation {
                                    accessibility.escape()
                                }
                            }
                        },
                        message: {
                            Text(resetData.scope)
                        }
                    )
                    .confirmationDialog(
                        "Reset all app-owned telemetry?",
                        isPresented: resetConfirmationBinding,
                        titleVisibility: .visible
                    ) {
                        Button("Reset App Telemetry", role: .destructive) {
                            confirmReset()
                        }
                        Button("Cancel", role: .cancel) {
                            resetInteraction.cancelReset()
                            resetData.cancelReset()
                            if accessibility.surface == .resetConfirmation {
                                accessibility.escape()
                            }
                        }
                    } message: {
                        Text("This action cannot be undone. Settings, Coding Agent source logs, and external user-saved files are preserved.")
                    }

                    resetOutcomeText(resetData.phase)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            syncFocus()
            accessibility.applyDiagnosticsTextAvailability(from: diagnostics)
        }
        .onChange(of: accessibility.navigation.focusedControl) { _, _ in syncFocus() }
        .onChange(of: diagnosticActions.previewText) { _, _ in
            accessibility.applyDiagnosticsTextAvailability(from: diagnostics)
        }
        .onChange(of: diagnosticActions.preparedPublicIssueText) { _, _ in
            accessibility.applyDiagnosticsTextAvailability(from: diagnostics)
        }
    }

    private var resetReviewBinding: Binding<Bool> {
        Binding(
            get: { resetInteraction == .reviewingResetScope },
            set: { isPresented in
                if !isPresented, resetInteraction == .reviewingResetScope {
                    resetInteraction.cancelReset()
                    if accessibility.surface == .resetConfirmation {
                        accessibility.escape()
                    }
                }
            }
        )
    }

    private var resetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { resetInteraction == .resetConfirmation },
            set: { isPresented in
                if !isPresented, resetInteraction == .resetConfirmation {
                    resetInteraction.cancelReset()
                    resetData.cancelReset()
                    if accessibility.surface == .resetConfirmation {
                        accessibility.escape()
                    }
                }
            }
        )
    }

    private func diagnosticConfirmationBinding(_ confirmation: DiagnosticActionController.Confirmation) -> Binding<Bool> {
        Binding(
            get: {
                diagnostics.pendingConfirmation == confirmation
                    || accessibility.surface == .diagnosticsConfirmation(diagnosticsAction(confirmation))
            },
            set: { isPresented in
                if !isPresented {
                    diagnostics.cancel(confirmation)
                    if case .diagnosticsConfirmation(let action) = accessibility.surface,
                       action == diagnosticsAction(confirmation) {
                        accessibility.escape()
                    }
                }
            }
        )
    }

    private func diagnosticsAction(_ confirmation: DiagnosticActionController.Confirmation) -> AccessibilityNavigation.DiagnosticsAction {
        switch confirmation {
        case .copy: .copy
        case .save: .save
        case .preparePublicIssue: .preparePublicIssue
        }
    }

    @ViewBuilder
    private func diagnosticText(
        _ text: String,
        identifier: String,
        control: AccessibilityNavigation.Control
    ) -> some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .focusable()
                .focused($focusedControl, equals: control)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .accessibilityFocusChrome(focusedControl == control)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Keyboard-reachable diagnostic text")
        .onTapGesture { accessibility.activate(control) }
    }

    @ViewBuilder
    private func diagnosticOutcomeText(_ outcome: DiagnosticActionController.Outcome) -> some View {
        switch outcome {
        case .idle, .previewed:
            EmptyView()
        case .copied:
            Text("Diagnostics copied after one-time confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saved:
            Text("Diagnostics saved to the location you selected. The app kept no managed copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saveCancelled:
            Text("Save cancelled; no diagnostic file was created by this action.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .publicIssuePrepared:
            EmptyView()
        case .failed(let message):
            Text("Diagnostics failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func confirmReset() {
        guard resetInteraction.canConfirmReset else { return }
        resetData.requestReset()
        resetData.confirmReset()
        if resetSucceeded(resetData.phase) {
            onResetCompleted()
        }
        resetInteraction.cancelReset()
        accessibility.activate(.confirmationConfirm)
    }

    private func syncFocus() {
        let control = accessibility.focusedControl
        focusedControl = control == .statusItem ? nil : control
    }

    private func resetSucceeded(_ phase: ResetDataController.Phase) -> Bool {
        switch phase {
        case .completed, .completedCleanupPending: true
        case .idle, .confirmationRequired, .resetting, .failed: false
        }
    }

    @ViewBuilder
    private func resetOutcomeText(_ phase: ResetDataController.Phase) -> some View {
        switch phase {
        case .idle, .confirmationRequired, .resetting:
            EmptyView()
        case .completed:
            Text("App telemetry was reset. Settings and Coding Agent source logs were preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .completedCleanupPending:
            Text("App telemetry was reset. Space cleanup is pending and will retry automatically; settings and Coding Agent source logs were preserved.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let message):
            Text("Reset failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

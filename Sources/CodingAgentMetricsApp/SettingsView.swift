import CodingAgentMetricsLifecycle
import SwiftUI

struct SettingsView: View {
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController
    let resetData: ResetDataController
    let diagnostics: DiagnosticActionController

    var body: some View {
        @Bindable var launchAtLogin = lifecycleServices.launchAtLogin
        @Bindable var enhancedTelemetry = telemetry
        @Bindable var diagnosticActions = diagnostics

        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.subheadline)
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .accessibilityHint("Starts the main app at login. No helper or daemon is installed.")

            if let failureMessage = launchAtLogin.failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Launch at Login error: \(failureMessage)")
            } else if launchAtLogin.status != .notRegistered {
                Text(launchAtLogin.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Toggle(
                "Enhanced telemetry",
                isOn: Binding(
                    get: { enhancedTelemetry.isEnabled },
                    set: { enhancedTelemetry.setEnabled($0) }
                )
            )
            .accessibilityHint("Starts only this app-owned local receiver. It does not change Claude Code, shell, or environment settings.")
            Text("Endpoint: \(enhancedTelemetry.endpoint)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let failureMessage = enhancedTelemetry.failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Enhanced telemetry error: \(failureMessage)")
            }
            Divider()
            Text("Privacy-Safe Diagnostics")
                .font(.subheadline)
            Text("Preview stays in memory. Copy, Save, and Prepare Public Issue each require their own one-time confirmation. Nothing is uploaded or submitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Preview Diagnostics") {
                diagnosticActions.preview()
            }
            .accessibilityHint("Builds an allowlisted diagnostic preview in memory without writing a file.")
            if let preview = diagnosticActions.previewText {
                ScrollView {
                    Text(preview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Button("Copy Diagnostics…") {
                    diagnosticActions.requestCopy()
                }
                .confirmationDialog(
                    DiagnosticActionController.Confirmation.copy.title,
                    isPresented: confirmationBinding(.copy),
                    titleVisibility: .visible
                ) {
                    Button(DiagnosticActionController.Confirmation.copy.confirmLabel) {
                        diagnosticActions.confirmCopy()
                    }
                    Button("Cancel", role: .cancel) {
                        diagnosticActions.cancel(.copy)
                    }
                } message: {
                    Text(DiagnosticActionController.Confirmation.copy.message)
                }

                Button("Save Diagnostics…") {
                    diagnosticActions.requestSave()
                }
                .confirmationDialog(
                    DiagnosticActionController.Confirmation.save.title,
                    isPresented: confirmationBinding(.save),
                    titleVisibility: .visible
                ) {
                    Button(DiagnosticActionController.Confirmation.save.confirmLabel) {
                        diagnosticActions.confirmSave()
                    }
                    Button("Cancel", role: .cancel) {
                        diagnosticActions.cancel(.save)
                    }
                } message: {
                    Text(DiagnosticActionController.Confirmation.save.message)
                }
            }
            Button("Prepare Public Issue…") {
                diagnosticActions.requestPreparePublicIssue()
            }
            .confirmationDialog(
                DiagnosticActionController.Confirmation.preparePublicIssue.title,
                isPresented: confirmationBinding(.preparePublicIssue),
                titleVisibility: .visible
            ) {
                Button(DiagnosticActionController.Confirmation.preparePublicIssue.confirmLabel) {
                    diagnosticActions.confirmPreparePublicIssue()
                }
                Button("Cancel", role: .cancel) {
                    diagnosticActions.cancel(.preparePublicIssue)
                }
            } message: {
                Text(DiagnosticActionController.Confirmation.preparePublicIssue.message)
            }
            if let issueText = diagnosticActions.preparedPublicIssueText {
                Text("Prepared text — review and paste it yourself:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(issueText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            if case .copied = diagnosticActions.outcome {
                Text("Diagnostics copied after one-time confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .saved = diagnosticActions.outcome {
                Text("Diagnostics saved to the location you selected. The app kept no managed copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .saveCancelled = diagnosticActions.outcome {
                Text("Save cancelled; no diagnostic file was created by this action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case let .failed(message) = diagnosticActions.outcome {
                Text("Diagnostics failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            Text("Reset Data")
                .font(.subheadline)
            Text("Deletes this app's telemetry and managed copies. Source logs and external user-saved files stay untouched; settings are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Review Reset Scope…", role: .destructive) {
                resetData.requestReset()
            }
            .disabled(!resetData.isAvailable || resetData.phase == .resetting)
            .accessibilityHint("Reviews the complete deletion scope before a separate destructive confirmation.")
            .confirmationDialog(
                "Reset all app-owned telemetry?",
                isPresented: Binding(
                    get: { resetData.isConfirmationPresented },
                    set: { if !$0 { resetData.cancelReset() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Reset App Telemetry", role: .destructive) {
                    resetData.confirmReset()
                }
                Button("Cancel", role: .cancel) {
                    resetData.cancelReset()
                }
            } message: {
                Text(resetData.scope)
            }
            if case .completed = resetData.phase {
                Text("App telemetry was reset. Settings and Coding Agent source logs were preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .completedCleanupPending = resetData.phase {
                Text("App telemetry was reset. Space cleanup is pending and will retry automatically; settings and Coding Agent source logs were preserved.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if case let .failed(message) = resetData.phase {
                Text("Reset failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Check for Updates") {
                lifecycleServices.updates.checkForUpdates()
            }
            .accessibilityHint("Checks the stable update feed and always requires user confirmation to install.")
        }
    }

    private func confirmationBinding(_ confirmation: DiagnosticActionController.Confirmation) -> Binding<Bool> {
        Binding(
            get: { diagnostics.pendingConfirmation == confirmation },
            set: { isPresented in
                if !isPresented { diagnostics.cancel(confirmation) }
            }
        )
    }
}

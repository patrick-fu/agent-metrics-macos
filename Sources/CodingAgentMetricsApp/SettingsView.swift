import CodingAgentMetricsLifecycle
import SwiftUI

struct SettingsView: View {
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController
    let resetData: ResetDataController

    var body: some View {
        @Bindable var launchAtLogin = lifecycleServices.launchAtLogin
        @Bindable var enhancedTelemetry = telemetry

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
}

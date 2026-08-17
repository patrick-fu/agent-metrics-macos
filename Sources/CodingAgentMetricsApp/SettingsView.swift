import CodingAgentMetricsLifecycle
import SwiftUI

struct SettingsView: View {
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController

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

            Button("Check for Updates") {
                lifecycleServices.updates.checkForUpdates()
            }
            .accessibilityHint("Checks the stable update feed and always requires user confirmation to install.")
        }
    }
}

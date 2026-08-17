import CodingAgentMetricsLifecycle
import SwiftUI

struct SettingsView: View {
    let lifecycleServices: AppLifecycleServices

    var body: some View {
        @Bindable var launchAtLogin = lifecycleServices.launchAtLogin

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

            Button("Check for Updates") {
                lifecycleServices.updates.checkForUpdates()
            }
            .accessibilityHint("Checks the stable update feed and always requires user confirmation to install.")
        }
    }
}

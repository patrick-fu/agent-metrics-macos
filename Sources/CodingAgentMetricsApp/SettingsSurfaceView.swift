import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import SwiftUI

struct SettingsSurfaceProjection: Equatable {
    struct Row: Equatable {
        let title: String
        let detail: String
        let accessibilityLabel: String
        let accessibilityHint: String
    }

    let launchAtLoginTitle: String
    let launchAtLoginStatusText: String?
    let launchAtLoginFailureText: String?
    let launchAtLoginAccessibilityLabel: String
    let launchAtLoginFailureAccessibilityLabel: String?
    let windowOptionTitles: [String]
    let cadenceOptionTitles: [String]
    let selectedWindowTitle: String
    let selectedCadenceTitle: String
    let telemetryTitle: String
    let telemetryIsEnabled: Bool
    let telemetryStateText: String
    let telemetryEndpointText: String
    let telemetryFailureText: String?
    let telemetryAccessibilityLabel: String
    let telemetryFailureAccessibilityLabel: String?
    let updateTitle: String
    let updateVersionText: String?
    let updateAccessibilityLabel: String
    let dataDiagnosticsRow: Row
    let aboutUpdatesRow: Row

    static func launchAtLoginStatusText(for status: LaunchAtLoginStatus) -> String? {
        switch status {
        case .notRegistered: nil
        case .enabled: "On"
        case .requiresApproval: "Approval is required in Login Items settings."
        case .unavailable: "Launch at Login is unavailable."
        }
    }

    static func make(
        launchAtLoginStatus: LaunchAtLoginStatus,
        launchAtLoginFailureText: String?,
        telemetryIsEnabled: Bool,
        telemetryEndpoint: String,
        telemetryFailureText: String?,
        window: OutputThroughputWindow,
        cadence: DisplayCadence,
        bundleInfo: [String: Any]
    ) -> SettingsSurfaceProjection {
        let productName = stringValue(for: "CFBundleName", in: bundleInfo) ?? "Agent Metrics"
        let diagnosticsDetail = "Privacy-safe diagnostics and troubleshooting"
        let aboutDetail = "About \(productName) and updates"
        let statusText = launchAtLoginFailureText == nil
            ? launchAtLoginStatusText(for: launchAtLoginStatus)
            : nil
        let versionText = versionText(for: bundleInfo)

        return SettingsSurfaceProjection(
            launchAtLoginTitle: "Launch at Login",
            launchAtLoginStatusText: statusText,
            launchAtLoginFailureText: launchAtLoginFailureText,
            launchAtLoginAccessibilityLabel: spoken(["Launch at Login", statusText]),
            launchAtLoginFailureAccessibilityLabel: launchAtLoginFailureText.map { "Launch at Login error: \($0)" },
            windowOptionTitles: OutputThroughputWindow.allCases.map(\.menuLabel),
            cadenceOptionTitles: DisplayCadence.allCases.map(cadenceTitle),
            selectedWindowTitle: window.menuLabel,
            selectedCadenceTitle: cadenceTitle(cadence),
            telemetryTitle: "Enhanced telemetry",
            telemetryIsEnabled: telemetryIsEnabled,
            telemetryStateText: telemetryIsEnabled ? "Enabled" : "Disabled",
            telemetryEndpointText: "Endpoint: \(telemetryEndpoint)",
            telemetryFailureText: telemetryFailureText,
            telemetryAccessibilityLabel: "Enhanced telemetry endpoint: \(telemetryEndpoint)",
            telemetryFailureAccessibilityLabel: telemetryFailureText.map { "Enhanced telemetry error: \($0)" },
            updateTitle: "Check for Updates",
            updateVersionText: versionText,
            updateAccessibilityLabel: spoken(["Check for Updates", versionText]),
            dataDiagnosticsRow: Row(
                title: "Data & Diagnostics",
                detail: diagnosticsDetail,
                accessibilityLabel: spoken(["Data and Diagnostics", diagnosticsDetail]),
                accessibilityHint: "Opens diagnostics preview, copy, save, and reset scope."
            ),
            aboutUpdatesRow: Row(
                title: "About & Updates",
                detail: aboutDetail,
                accessibilityLabel: spoken(["About and Updates", aboutDetail]),
                accessibilityHint: "Opens version, update status, and privacy details."
            )
        )
    }

    private static func cadenceTitle(_ cadence: DisplayCadence) -> String {
        "\(Int(cadence.seconds))s"
    }

    private static func versionText(for info: [String: Any]) -> String? {
        guard
            let shortVersion = stringValue(for: "CFBundleShortVersionString", in: info),
            let build = stringValue(for: "CFBundleVersion", in: info)
        else { return nil }
        return "Version \(shortVersion) (Build \(build))"
    }

    private static func stringValue(for key: String, in info: [String: Any]) -> String? {
        guard let value = info[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Joins the visible fragments of one control into a single spoken label.
    private static func spoken(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct SettingsSurfaceView: View {
    let lifecycleServices: AppLifecycleServices
    let telemetry: EnhancedTelemetryController
    @ObservedObject var accessibility: AccessibilitySession
    @Binding var selectedWindow: OutputThroughputWindow
    @Binding var selectedCadence: DisplayCadence
    var onWindowChange: (OutputThroughputWindow) -> Void
    var onCadenceChange: (DisplayCadence) -> Void
    var openDataDiagnostics: () -> Void
    var openAboutUpdates: () -> Void
    @FocusState private var focusedControl: AccessibilityNavigation.Control?

    init(
        lifecycleServices: AppLifecycleServices,
        telemetry: EnhancedTelemetryController,
        accessibility: AccessibilitySession? = nil,
        selectedWindow: Binding<OutputThroughputWindow> = .constant(.default),
        selectedCadence: Binding<DisplayCadence> = .constant(.default),
        onWindowChange: @escaping (OutputThroughputWindow) -> Void = { _ in },
        onCadenceChange: @escaping (DisplayCadence) -> Void = { _ in },
        openDataDiagnostics: @escaping () -> Void,
        openAboutUpdates: @escaping () -> Void
    ) {
        self.lifecycleServices = lifecycleServices
        self.telemetry = telemetry
        _accessibility = ObservedObject(wrappedValue: accessibility ?? AccessibilitySession())
        _selectedWindow = selectedWindow
        _selectedCadence = selectedCadence
        self.onWindowChange = onWindowChange
        self.onCadenceChange = onCadenceChange
        self.openDataDiagnostics = openDataDiagnostics
        self.openAboutUpdates = openAboutUpdates
    }

    var projection: SettingsSurfaceProjection {
        SettingsSurfaceProjection.make(
            launchAtLoginStatus: lifecycleServices.launchAtLogin.status,
            launchAtLoginFailureText: lifecycleServices.launchAtLogin.failureMessage,
            telemetryIsEnabled: telemetry.isEnabled,
            telemetryEndpoint: telemetry.endpoint,
            telemetryFailureText: telemetry.failureMessage,
            window: selectedWindow,
            cadence: selectedCadence,
            bundleInfo: Bundle.main.infoDictionary ?? [:]
        )
    }

    var body: some View {
        @Bindable var launchAtLogin = lifecycleServices.launchAtLogin
        @Bindable var enhancedTelemetry = telemetry
        let projection = self.projection

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                generalCard(projection, launchAtLogin: launchAtLogin)
                displayCard(projection)
            }
            telemetryCard(projection, enhancedTelemetry: enhancedTelemetry)
            updatesCard(projection)
            navigationRow(
                projection.dataDiagnosticsRow,
                systemImage: "checkmark.shield",
                control: .openDataDiagnostics,
                action: openDataDiagnostics
            )
            navigationRow(
                projection.aboutUpdatesRow,
                systemImage: "info.circle",
                control: .openAboutUpdates,
                action: openAboutUpdates
            )
        }
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
        .onAppear { syncFocus() }
        .onChange(of: accessibility.navigation.focusedControl) { _, _ in syncFocus() }
    }

    private func generalCard(
        _ projection: SettingsSurfaceProjection,
        launchAtLogin: LaunchAtLoginController
    ) -> some View {
        card("General") {
            Toggle(projection.launchAtLoginTitle, isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: {
                    accessibility.activate(.launchAtLogin)
                    launchAtLogin.setEnabled($0)
                }
            ))
            .toggleStyle(.checkbox)
            .focused($focusedControl, equals: .launchAtLogin)
            .accessibilityFocusChrome(focusedControl == .launchAtLogin)
            .accessibilityHint("Starts the main app at login. No helper or daemon is installed.")

            if let failure = projection.launchAtLoginFailureText,
               let label = projection.launchAtLoginFailureAccessibilityLabel {
                caption(failure)
                    .foregroundStyle(.red)
                    .accessibilityLabel(label)
            } else if let status = projection.launchAtLoginStatusText {
                caption(status)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(projection.launchAtLoginAccessibilityLabel)
            }
        }
    }

    private func displayCard(_ projection: SettingsSurfaceProjection) -> some View {
        card("Display") {
            Picker("Aggregate window", selection: $selectedWindow) {
                ForEach(Array(zip(OutputThroughputWindow.allCases, projection.windowOptionTitles)), id: \.0) { window, title in
                    Text(title).tag(window)
                }
            }
            .focused($focusedControl, equals: .aggregateWindow)
            .accessibilityFocusChrome(focusedControl == .aggregateWindow)
            .onChange(of: selectedWindow) { _, window in
                onWindowChange(window)
            }

            Picker("Menu bar cadence", selection: $selectedCadence) {
                ForEach(Array(zip(DisplayCadence.allCases, projection.cadenceOptionTitles)), id: \.0) { cadence, title in
                    Text(title).tag(cadence)
                }
            }
            .focused($focusedControl, equals: .displayCadence)
            .accessibilityFocusChrome(focusedControl == .displayCadence)
            .onChange(of: selectedCadence) { _, cadence in
                onCadenceChange(cadence)
            }

            caption("How often metrics are refreshed.")
                .foregroundStyle(.secondary)
        }
    }

    private func telemetryCard(
        _ projection: SettingsSurfaceProjection,
        enhancedTelemetry: EnhancedTelemetryController
    ) -> some View {
        card(
            "Enhanced Telemetry",
            badge: projection.telemetryStateText,
            badgeIsOn: projection.telemetryIsEnabled
        ) {
            Toggle(projection.telemetryTitle, isOn: Binding(
                get: { enhancedTelemetry.isEnabled },
                set: {
                    accessibility.activate(.enhancedTelemetry)
                    enhancedTelemetry.setEnabled($0)
                }
            ))
            .toggleStyle(.switch)
            .focused($focusedControl, equals: .enhancedTelemetry)
            .accessibilityFocusChrome(focusedControl == .enhancedTelemetry)
            .accessibilityHint("Starts only this app-owned local receiver. It does not change Claude Code, shell, or environment settings.")

            caption(projection.telemetryEndpointText)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel(projection.telemetryAccessibilityLabel)

            if let failure = projection.telemetryFailureText,
               let label = projection.telemetryFailureAccessibilityLabel {
                caption(failure)
                    .foregroundStyle(.red)
                    .accessibilityLabel(label)
            }
        }
    }

    private func updatesCard(_ projection: SettingsSurfaceProjection) -> some View {
        card("Updates") {
            HStack(spacing: 8) {
                if let versionText = projection.updateVersionText {
                    caption(versionText)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                Button(projection.updateTitle) {
                    accessibility.activate(.checkForUpdates)
                    lifecycleServices.updates.checkForUpdates()
                }
                .focused($focusedControl, equals: .checkForUpdates)
                .accessibilityFocusChrome(focusedControl == .checkForUpdates)
                .accessibilityLabel(projection.updateAccessibilityLabel)
                .accessibilityHint("Checks the stable update feed and always requires user confirmation to install.")
            }
        }
    }

    private func navigationRow(
        _ row: SettingsSurfaceProjection.Row,
        systemImage: String,
        control: AccessibilityNavigation.Control,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    caption(row.detail)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: control)
        .accessibilityFocusChrome(focusedControl == control)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.accessibilityHint)
    }

    private func card<Content: View>(
        _ title: String,
        badge: String? = nil,
        badgeIsOn: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeIsOn ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncFocus() {
        let control = accessibility.focusedControl
        focusedControl = control == .statusItem ? nil : control
    }
}

import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import Foundation
import Testing

@testable import CodingAgentMetricsApp

struct SettingsSurfaceViewTests {
    static let endpoint = OTLPReceiverConfiguration().endpoint.absoluteString
    static func bundleInfo(
        name: String = "Agent Metrics",
        version: String = "9.9.9",
        build: String = "4242"
    ) -> [String: Any] {
        [
            "CFBundleName": name,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
    }

    // MARK: - Launch at Login

    @Test @MainActor
    func launchAtLoginStatusTextTracksControllerForEveryRegistrationState() {
        for status in [
            LaunchAtLoginStatus.notRegistered,
            .enabled,
            .requiresApproval,
            .unavailable,
        ] {
            let controller = LaunchAtLoginController(service: ScriptedLaunchAtLoginService(status: status))
            let expected = status == .notRegistered ? nil : controller.statusMessage
            #expect(SettingsSurfaceProjection.launchAtLoginStatusText(for: status) == expected)
        }
    }

    @Test
    func launchAtLoginCaptionAggregatesTitleAndStatus() {
        let projection = projection(launchAtLoginStatus: .requiresApproval)

        #expect(projection.launchAtLoginTitle == "Launch at Login")
        #expect(projection.launchAtLoginStatusText == "Approval is required in Login Items settings.")
        #expect(projection.launchAtLoginFailureText == nil)
        #expect(projection.launchAtLoginAccessibilityLabel == "Launch at Login, Approval is required in Login Items settings.")
        #expect(projection.launchAtLoginFailureAccessibilityLabel == nil)
    }

    @Test
    func launchAtLoginFailureReplacesStatusWithTheExistingErrorLabel() {
        let projection = projection(
            launchAtLoginStatus: .enabled,
            launchAtLoginFailureText: "Unable to change Launch at Login: denied"
        )

        #expect(projection.launchAtLoginStatusText == nil)
        #expect(projection.launchAtLoginFailureText == "Unable to change Launch at Login: denied")
        #expect(
            projection.launchAtLoginFailureAccessibilityLabel
                == "Launch at Login error: Unable to change Launch at Login: denied"
        )
    }

    // MARK: - Display

    @Test
    func displayOptionsReuseWindowAndCadenceMenuLabels() {
        let projection = projection(window: .tenMinutes, cadence: .sixtySeconds)

        #expect(projection.windowOptionTitles == ["3m", "5m", "10m"])
        #expect(projection.cadenceOptionTitles == ["15s", "30s", "60s"])
        #expect(projection.windowOptionTitles.count == OutputThroughputWindow.allCases.count)
        #expect(projection.cadenceOptionTitles.count == DisplayCadence.allCases.count)
        #expect(projection.selectedWindowTitle == "10m")
        #expect(projection.selectedCadenceTitle == "60s")
    }

    // MARK: - Enhanced telemetry

    @Test
    func telemetryEndpointTextComesFromTheInjectedEndpoint() {
        let projection = projection(telemetryIsEnabled: true)

        #expect(projection.telemetryTitle == "Enhanced telemetry")
        #expect(projection.telemetryEndpointText == "Endpoint: \(Self.endpoint)")
        #expect(projection.telemetryAccessibilityLabel == "Enhanced telemetry endpoint: \(Self.endpoint)")
        #expect(projection.telemetryStateText == "Enabled")
        #expect(projection.telemetryFailureText == nil)
        #expect(projection.telemetryFailureAccessibilityLabel == nil)
    }

    @Test
    func telemetryFailureKeepsTheExistingErrorLabel() {
        let projection = projection(telemetryFailureText: "Telemetry runtime is unavailable.")

        #expect(projection.telemetryStateText == "Disabled")
        #expect(projection.telemetryFailureAccessibilityLabel == "Enhanced telemetry error: Telemetry runtime is unavailable.")
        #expect(projection.telemetryAccessibilityLabel == "Enhanced telemetry endpoint: \(Self.endpoint)")
    }

    @Test @MainActor
    func telemetryFailureTextIsTakenFromTheControllerThatOwnsTheRuntime() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = EnhancedTelemetryController(runtime: nil, defaults: defaults)
        controller.setEnabled(true)
        let projection = projection(
            telemetryIsEnabled: controller.isEnabled,
            telemetryEndpoint: controller.endpoint,
            telemetryFailureText: controller.failureMessage
        )

        #expect(controller.isEnabled == false)
        #expect(controller.endpoint == Self.endpoint)
        #expect(projection.telemetryFailureText == "Telemetry runtime is unavailable.")
        #expect(projection.telemetryEndpointText == "Endpoint: \(Self.endpoint)")
    }

    // MARK: - Updates

    @Test
    func updateVersionTextComesFromInjectedBundleInfo() {
        let projection = projection()

        #expect(projection.updateTitle == "Check for Updates")
        #expect(projection.updateVersionText == "Version 9.9.9 (Build 4242)")
        #expect(projection.updateAccessibilityLabel == "Check for Updates, Version 9.9.9 (Build 4242)")
    }

    @Test
    func updateVersionTextIsOmittedWhenBundleMetadataIsMissingOrEmpty() {
        let cases: [[String: Any]] = [
            [:],
            ["CFBundleShortVersionString": "9.9.9"],
            ["CFBundleShortVersionString": "", "CFBundleVersion": "4242"],
            ["CFBundleShortVersionString": 42, "CFBundleVersion": NSNull()],
        ]

        for info in cases {
            let projection = projection(bundleInfo: info)
            #expect(projection.updateVersionText == nil)
            #expect(projection.updateAccessibilityLabel == "Check for Updates")
        }
    }

    // MARK: - Navigation rows

    @Test
    func navigationRowsAggregateSpokenLabelsAndNameTheirDestination() {
        let projection = projection()

        #expect(projection.dataDiagnosticsRow.title == "Data & Diagnostics")
        #expect(projection.dataDiagnosticsRow.detail == "Privacy-safe diagnostics and troubleshooting")
        #expect(
            projection.dataDiagnosticsRow.accessibilityLabel
                == "Data and Diagnostics, Privacy-safe diagnostics and troubleshooting"
        )
        #expect(
            projection.dataDiagnosticsRow.accessibilityHint
                == "Opens diagnostics preview, copy, save, and reset scope."
        )
        #expect(projection.aboutUpdatesRow.title == "About & Updates")
        #expect(projection.aboutUpdatesRow.detail == "About Agent Metrics and updates")
        #expect(
            projection.aboutUpdatesRow.accessibilityLabel
                == "About and Updates, About Agent Metrics and updates"
        )
        #expect(
            projection.aboutUpdatesRow.accessibilityHint
                == "Opens version, update status, and privacy details."
        )
        #expect(!projection.dataDiagnosticsRow.accessibilityLabel.contains("&"))
        #expect(!projection.aboutUpdatesRow.accessibilityLabel.contains("&"))
    }

    @Test
    func aboutRowDetailUsesTheBundledProductName() {
        let projection = projection(bundleInfo: ["CFBundleName": "Metric Probe"])

        #expect(projection.aboutUpdatesRow.detail == "About Metric Probe and updates")
        #expect(
            projection.aboutUpdatesRow.accessibilityLabel
                == "About and Updates, About Metric Probe and updates"
        )
    }

    // MARK: - View

    @Test @MainActor
    func settingsHomeProjectsTheControllersItIsGiven() {
        let (view, cleanup) = settingsHome(window: .fiveMinutes, cadence: .fifteenSeconds)
        defer { cleanup() }
        _ = view.body

        #expect(view.projection.telemetryEndpointText == "Endpoint: \(Self.endpoint)")
        #expect(view.projection.selectedWindowTitle == "5m")
        #expect(view.projection.selectedCadenceTitle == "15s")
        #expect(view.projection.launchAtLoginStatusText == nil)
    }

    @Test @MainActor
    func settingsHomeConstructsBodyWithoutMutatingNavigationOrPreferences() {
        let session = AccessibilitySession()
        session.openPanel()
        session.activate(.settings)
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let telemetry = EnhancedTelemetryController(runtime: nil, defaults: defaults)
        let launchAtLogin = LaunchAtLoginController(service: ScriptedLaunchAtLoginService(status: .notRegistered))
        let view = SettingsSurfaceView(
            lifecycleServices: AppLifecycleServices(
                launchAtLogin: launchAtLogin,
                updates: UpdateCheckController(service: InertUpdateService())
            ),
            telemetry: telemetry,
            accessibility: session,
            selectedWindow: .constant(.threeMinutes),
            selectedCadence: .constant(.thirtySeconds),
            openDataDiagnostics: {},
            openAboutUpdates: {}
        )
        _ = view.body

        #expect(session.surface == .settings)
        #expect(session.focusedControl == .back)
        #expect(telemetry.isEnabled == false)
        #expect(launchAtLogin.status == .notRegistered)
    }

    @Test @MainActor
    func settingsHomeSourceUsesDynamicColorsAndNoHardcodedValues() throws {
        let source = try Self.sourceContents("Sources/CodingAgentMetricsApp/SettingsSurfaceView.swift")
        let forbiddenPatterns = [
            "Color(red:",
            "Color(hue:",
            "NSColor",
            "UIColor",
            "4318",
            "0.2.0",
            "Build 5",
        ]

        for pattern in forbiddenPatterns {
            #expect(!source.contains(pattern), "unexpected hardcoded styling or value: \(pattern)")
        }
        #expect(source.range(of: #"#[0-9A-Fa-f]{6}"#, options: .regularExpression) == nil)
        #expect(source.contains("AppIdentity.popoverWidth"))
        #expect(source.contains("Bundle.main.infoDictionary"))
    }

    // MARK: - Fixtures

    private static func sourceContents(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "cam-settings-surface-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func projection(
        launchAtLoginStatus: LaunchAtLoginStatus = .notRegistered,
        launchAtLoginFailureText: String? = nil,
        telemetryIsEnabled: Bool = false,
        telemetryEndpoint: String = SettingsSurfaceViewTests.endpoint,
        telemetryFailureText: String? = nil,
        window: OutputThroughputWindow = .threeMinutes,
        cadence: DisplayCadence = .thirtySeconds,
        bundleInfo: [String: Any] = SettingsSurfaceViewTests.bundleInfo()
    ) -> SettingsSurfaceProjection {
        SettingsSurfaceProjection.make(
            launchAtLoginStatus: launchAtLoginStatus,
            launchAtLoginFailureText: launchAtLoginFailureText,
            telemetryIsEnabled: telemetryIsEnabled,
            telemetryEndpoint: telemetryEndpoint,
            telemetryFailureText: telemetryFailureText,
            window: window,
            cadence: cadence,
            bundleInfo: bundleInfo
        )
    }

    @MainActor
    private func settingsHome(
        window: OutputThroughputWindow,
        cadence: DisplayCadence
    ) -> (view: SettingsSurfaceView, cleanup: () -> Void) {
        let (defaults, suite) = Self.isolatedDefaults()
        let view = SettingsSurfaceView(
            lifecycleServices: AppLifecycleServices(
                launchAtLogin: LaunchAtLoginController(service: ScriptedLaunchAtLoginService(status: .notRegistered)),
                updates: UpdateCheckController(service: InertUpdateService())
            ),
            telemetry: EnhancedTelemetryController(
                runtime: nil,
                defaults: defaults
            ),
            accessibility: AccessibilitySession(),
            selectedWindow: .constant(window),
            selectedCadence: .constant(cadence),
            openDataDiagnostics: {},
            openAboutUpdates: {}
        )
        return (view, { defaults.removePersistentDomain(forName: suite) })
    }
}

@MainActor
private final class ScriptedLaunchAtLoginService: LaunchAtLoginService {
    private let status: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func registrationStatus() -> LaunchAtLoginStatus { status }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class InertUpdateService: UpdateCheckingService {
    func checkForUpdates() {}
}

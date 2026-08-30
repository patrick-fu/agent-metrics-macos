import CodingAgentMetricsLifecycle
import Foundation
import Testing
@testable import CodingAgentMetricsApp

struct AboutUpdatesSurfaceViewTests {
    @Test
    func projectionShowsInjectedIdentityMetricsAndPrivacyBoundaries() {
        let presentation = AppAboutPresentation(info: [
            "CFBundleName": "Agent Metrics",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "654",
            "LSMinimumSystemVersion": "14.0",
            "SUFeedURL": "https://updates.example.invalid/stable/appcast.xml",
        ])
        let projection = AboutUpdatesSurfaceProjection.make(presentation)

        #expect(projection.name == "Agent Metrics")
        #expect(projection.versionText == "Version 9.8.7 (Build 654)")
        #expect(projection.minimumOSText == "Requires macOS 14.0")
        #expect(projection.metrics.map(\.name) == [
            "Output Throughput",
            "Decode TPS",
            "Token Burn",
            "Calls",
        ])
        #expect(projection.metrics.map(\.definition) == presentation.metrics.map(\.definition))
        #expect(projection.localFirstSummary == "Metrics are read and stored locally.")
        #expect(projection.privacyBoundary == "No prompts, code, or tool-result bodies are stored in app telemetry.")
        #expect(projection.networkBoundary == "Network access is used for update checks against the configured stable feed; diagnostics require user review before any external sharing.")
        #expect(projection.checkForUpdatesTitle == "Check for Updates")
        #expect(projection.stableFeedText.contains("https://updates.example.invalid/stable/appcast.xml"))
    }

    @Test
    func projectionUsesUnavailableWhenBundleIdentityIsMissing() {
        let projection = AboutUpdatesSurfaceProjection.make(AppAboutPresentation(info: [:]))

        #expect(projection.name == AppAboutPresentation.unavailable)
        #expect(projection.versionText == "Version Unavailable (Build Unavailable)")
        #expect(projection.minimumOSText == "Requires macOS Unavailable")
        #expect(projection.stableFeedText.contains(AppAboutPresentation.unavailable))
    }

    @Test @MainActor
    func viewConstructsFromInjectedPresentationWithoutCheckingForUpdates() {
        var checks = 0
        let updates = UpdateCheckController(service: CountingUpdateService(onCheck: { checks += 1 }))
        let view = AboutUpdatesSurfaceView(
            presentation: AppAboutPresentation(info: [
                "CFBundleName": "Metric Probe",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "9",
            ]),
            updates: updates
        )

        _ = view.body
        #expect(view.projection.name == "Metric Probe")
        #expect(view.projection.versionText == "Version 1.2.3 (Build 9)")
        #expect(checks == 0)
    }

    @Test
    func sourceDoesNotHardcodeVersionBuildOrFeed() throws {
        let source = try Self.sourceContents("Sources/CodingAgentMetricsApp/AboutUpdatesSurfaceView.swift")
        for pattern in ["0.2.0", "Build 5", "4318", "http://", "Color(red:"] {
            #expect(!source.contains(pattern), "unexpected hardcoded value: \(pattern)")
        }
        #expect(source.contains("AppAboutPresentation"))
        #expect(source.contains("AppIdentity.popoverWidth"))
        #expect(source.contains("aboutCheckForUpdates"))
    }

    private static func sourceContents(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

@MainActor
private final class CountingUpdateService: UpdateCheckingService {
    private let onCheck: () -> Void

    init(onCheck: @escaping () -> Void) {
        self.onCheck = onCheck
    }

    func checkForUpdates() {
        onCheck()
    }
}

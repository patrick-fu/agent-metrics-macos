import Foundation
import Testing
@testable import CodingAgentMetricsApp

struct AppAboutPresentationTests {
    @Test
    func presentsBundleIdentityAndStableUpdateFeedFromInjectedInfo() {
        let presentation = AppAboutPresentation(info: [
            "CFBundleName": "Agent Metrics",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "654",
            "LSMinimumSystemVersion": "14.0",
            "SUFeedURL": "https://updates.example.invalid/stable/appcast.xml",
        ])

        #expect(presentation.name == "Agent Metrics")
        #expect(presentation.shortVersion == "9.8.7")
        #expect(presentation.build == "654")
        #expect(presentation.minimumOS == "14.0")
        #expect(presentation.stableFeedURL == "https://updates.example.invalid/stable/appcast.xml")
        #expect(URL(string: presentation.stableFeedURL)?.scheme == "https")
    }

    @Test
    func distinguishesEachMetricWithoutRelabelingTokenBurnOrDecodeTPS() {
        let presentation = AppAboutPresentation(info: [:])
        let definitions = Dictionary(uniqueKeysWithValues: presentation.metrics.map { ($0.name, $0.definition) })

        #expect(presentation.metrics.count == 4)
        #expect(definitions["Output Throughput"] == "Observed output tokens across selected agents and models divided by a shared sliding-window duration.")
        #expect(definitions["Decode TPS"] == "Per-model-call decode rate excluding time to first token.")
        #expect(definitions["Token Burn"] == "Normalized, mutually exclusive input and output token parts consumed over a sliding window.")
        #expect(definitions["Calls"] == "Distinct stable Model Call IDs observed over a sliding window, expressed per minute.")
        #expect(definitions["Token Burn"]?.contains("TPM") == false)
        #expect(definitions["Output Throughput"]?.contains("Decode") == false)
    }

    @Test
    func explainsLocalFirstPrivacyAndUpdateNetworkBoundaryWithoutAbsoluteNetworkClaims() {
        let presentation = AppAboutPresentation(info: [:])

        #expect(presentation.localFirstSummary == "Metrics are read and stored locally.")
        #expect(presentation.privacyBoundary == "No prompts, code, or tool-result bodies are stored in app telemetry.")
        #expect(presentation.networkBoundary == "Network access is used for update checks against the configured stable feed; diagnostics require user review before any external sharing.")
        #expect(presentation.privacySummary == "Metrics are read and stored locally. No prompts, code, or tool-result bodies are stored in app telemetry. Network access is used for update checks against the configured stable feed; diagnostics require user review before any external sharing.")
        #expect(!presentation.networkBoundary.localizedCaseInsensitiveContains("never uses the network"))
        #expect(!presentation.privacyBoundary.localizedCaseInsensitiveContains("anonymous"))
    }

    @Test
    func usesAStableUnavailableValueForMissingOrInvalidBundleValues() {
        let presentation = AppAboutPresentation(info: [
            "CFBundleName": 42,
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "",
            "LSMinimumSystemVersion": NSNull(),
            "SUFeedURL": "http://updates.example.invalid/appcast.xml",
        ])

        #expect(presentation.name == "Unavailable")
        #expect(presentation.shortVersion == "Unavailable")
        #expect(presentation.build == "Unavailable")
        #expect(presentation.minimumOS == "Unavailable")
        #expect(presentation.stableFeedURL == "Unavailable")
    }
}

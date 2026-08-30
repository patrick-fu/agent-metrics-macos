import Foundation

struct AppAboutPresentation: Equatable {
    struct Metric: Equatable {
        let name: String
        let definition: String
    }

    static let unavailable = "Unavailable"

    let name: String
    let shortVersion: String
    let build: String
    let minimumOS: String
    let stableFeedURL: String
    let metrics: [Metric]
    let localFirstSummary: String
    let privacyBoundary: String
    let networkBoundary: String
    let privacySummary: String

    init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        name = Self.stringValue(for: "CFBundleName", in: info)
        shortVersion = Self.stringValue(for: "CFBundleShortVersionString", in: info)
        build = Self.stringValue(for: "CFBundleVersion", in: info)
        minimumOS = Self.stringValue(for: "LSMinimumSystemVersion", in: info)
        stableFeedURL = Self.httpsURLValue(for: "SUFeedURL", in: info)
        metrics = [
            Metric(
                name: "Output Throughput",
                definition: "Observed output tokens across selected agents and models divided by a shared sliding-window duration."
            ),
            Metric(
                name: "Decode TPS",
                definition: "Per-model-call decode rate excluding time to first token."
            ),
            Metric(
                name: "Token Burn",
                definition: "Normalized, mutually exclusive input and output token parts consumed over a sliding window."
            ),
            Metric(
                name: "Calls",
                definition: "Distinct stable Model Call IDs observed over a sliding window, expressed per minute."
            ),
        ]
        localFirstSummary = "Metrics are read and stored locally."
        privacyBoundary = "No prompts, code, or tool-result bodies are stored in app telemetry."
        networkBoundary = "Network access is used for update checks against the configured stable feed; diagnostics require user review before any external sharing."
        privacySummary = "\(localFirstSummary) \(privacyBoundary) \(networkBoundary)"
    }

    private static func stringValue(for key: String, in info: [String: Any]) -> String {
        guard let value = info[key] as? String, !value.isEmpty else { return unavailable }
        return value
    }

    private static func httpsURLValue(for key: String, in info: [String: Any]) -> String {
        let value = stringValue(for: key, in: info)
        guard value != unavailable, URL(string: value)?.scheme == "https" else { return unavailable }
        return value
    }
}

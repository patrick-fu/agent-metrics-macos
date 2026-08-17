import Foundation

public enum FixtureLocator {
    public static var syntheticCodexTokenCountV1: URL {
        guard let url = Bundle.module.url(
            forResource: "synthetic-codex-token-count-v1",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ) else {
            preconditionFailure("Missing synthetic-codex-token-count-v1.jsonl fixture")
        }
        return url
    }
}

public struct SyntheticCodexSourceAdapter: SourceAdapter {
    public var fixtureURL: URL

    public init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    public func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        let data = try Data(contentsOf: fixtureURL)
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return try decodeObservation(trimmed, clock: clock)
        }
    }

    private func decodeObservation(_ line: String, clock: any Clock) throws -> UsageObservation {
        let payload = try JSONDecoder().decode(SyntheticCodexLine.self, from: Data(line.utf8))
        guard payload.schemaVersion == "synthetic-codex-token-count-v1" else {
            throw AdapterError.unsupportedSchema(payload.schemaVersion)
        }
        guard payload.codingAgent == "codex" else {
            throw AdapterError.unsupportedAgent(payload.codingAgent)
        }
        return UsageObservation(
            schemaVersion: payload.schemaVersion,
            codingAgent: .codex,
            model: ModelIdentity(raw: payload.modelRaw, display: payload.modelDisplay),
            sessionID: payload.sessionID,
            turnID: payload.turnID,
            observedAt: clock.now.addingTimeInterval(payload.observedOffsetSeconds),
            outputTokens: payload.usage.outputTokens
        )
    }
}

public enum AdapterError: Error, Equatable {
    case unsupportedSchema(String)
    case unsupportedAgent(String)
}

private struct SyntheticCodexLine: Decodable {
    var schemaVersion: String
    var codingAgent: String
    var modelRaw: String
    var modelDisplay: String
    var sessionID: String
    var turnID: String
    var observedOffsetSeconds: TimeInterval
    var usage: Usage

    struct Usage: Decodable {
        var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case outputTokens = "output_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case codingAgent = "coding_agent"
        case modelRaw = "model_raw"
        case modelDisplay = "model_display"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case observedOffsetSeconds = "observed_offset_seconds"
        case usage
    }
}

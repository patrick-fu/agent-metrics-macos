import CryptoKit
import Foundation

public enum ClaudeTranscriptParser {
    public static let semanticVersion = "1.0.0"
    public static let schemaVersion = "claude-code-transcript-v1"
    public static let sourceID = "claude-code"
    public static let authority = "claude-code-transcript-usage"

    public static func fileIdentity(fromFileName name: String) -> String? {
        guard name.hasSuffix(".jsonl"), !name.contains(".jsonl.") else { return nil }
        let identity = String(name.dropLast(".jsonl".count))
        guard !identity.isEmpty else { return nil }
        return identity
    }

    public static func parseLine(_ line: String) -> ParsedClaudeTranscriptLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String,
            let sessionID = object["sessionId"] as? String,
            !sessionID.isEmpty
        else {
            return .unknownSchema
        }
        let timestamp = object["timestamp"] as? String
        switch type {
        case "user":
            return .ignored
        case "assistant":
            guard
                let uuid = object["uuid"] as? String,
                !uuid.isEmpty,
                let message = object["message"] as? [String: Any],
                message["role"] as? String == "assistant",
                let model = message["model"] as? String,
                !model.isEmpty,
                let usage = message["usage"] as? [String: Any],
                let outputTokens = intValue(usage["output_tokens"]),
                outputTokens >= 0
            else {
                return .unknownSchema
            }
            return .messageTotal(
                identity: uuid,
                sessionID: sessionID,
                model: model,
                outputTokens: outputTokens,
                timestamp: timestamp
            )
        case "system":
            guard
                object["subtype"] as? String == "session_usage",
                let usage = object["usage"] as? [String: Any],
                let outputTokens = intValue(usage["output_tokens"]),
                outputTokens >= 0
            else {
                return .unknownSchema
            }
            return .sessionTotal(sessionID: sessionID, outputTokens: outputTokens, timestamp: timestamp)
        default:
            return .unknownSchema
        }
    }

    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as Double where value.rounded() == value:
            return Int(value)
        default:
            return nil
        }
    }
}

public enum ParsedClaudeTranscriptLine: Equatable {
    case messageTotal(identity: String, sessionID: String, model: String, outputTokens: Int, timestamp: String?)
    case sessionTotal(sessionID: String, outputTokens: Int, timestamp: String?)
    case ignored
    case unknownSchema
}

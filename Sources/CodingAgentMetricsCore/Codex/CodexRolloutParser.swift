import CryptoKit
import Foundation

public enum CodexRolloutParser {
    public static let semanticVersion = "1.0.0"
    public static let schemaVersion = "codex-rollout-v1"
    public static let sourceID = "codex"
    public static let authority = "codex-rollout-token-count"

    private static let knownLineTypes: Set<String> = [
        "session_meta",
        "turn_context",
        "event_msg",
        "response_item",
        "compacted",
        "world_state",
        "inter_agent_communication",
        "inter_agent_communication_metadata",
    ]

    private static let ignoredEventTypes: Set<String> = [
        "user_message",
        "agent_message",
        "agent_reasoning",
        "agent_reasoning_raw_content",
        "thread_settings_applied",
        "thread_goal_updated",
        "thread_rolled_back",
        "turn_aborted",
        "warning",
        "error",
    ]

    public static func fileIdentity(fromFileName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), !name.contains(".jsonl.") else {
            return nil
        }
        let core = String(name.dropFirst("rollout-".count).dropLast(".jsonl".count))
        guard core.count > 20 else { return nil }
        let ids = core.dropFirst(20)
        return String(ids.split(separator: "_").first ?? ids)
    }

    public static func parseLine(_ line: String) -> ParsedRolloutLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return .unknownSchema
        }

        let ordinal = intValue(object["ordinal"]).flatMap { $0 >= 0 ? UInt64($0) : nil }
        let timestamp = object["timestamp"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]

        switch type {
        case "session_meta":
            let id = (payload["id"] as? String) ?? (payload["session_id"] as? String)
            guard let id, !id.isEmpty else { return .unknownSchema }
            return .sessionMeta(id: id, timestamp: timestamp, ordinal: ordinal)
        case "turn_context":
            return .turnContext(
                turnID: payload["turn_id"] as? String,
                model: payload["model"] as? String,
                timestamp: timestamp,
                ordinal: ordinal
            )
        case "event_msg":
            return parseEvent(payload, timestamp: timestamp, ordinal: ordinal)
        default:
            return knownLineTypes.contains(type) ? .ignored : .unknownSchema
        }
    }

    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseEvent(
        _ payload: [String: Any],
        timestamp: String?,
        ordinal: UInt64?
    ) -> ParsedRolloutLine {
        guard let eventType = payload["type"] as? String else { return .unknownSchema }
        switch eventType {
        case "token_count":
            let info = payload["info"] as? [String: Any] ?? [:]
            let total = intValue((info["total_token_usage"] as? [String: Any])?["output_tokens"])
            let last = intValue((info["last_token_usage"] as? [String: Any])?["output_tokens"])
            guard
                let timestamp,
                parseTimestamp(timestamp) != nil,
                let total,
                total >= 0,
                last.map({ $0 >= 0 }) ?? true
            else { return .unknownSchema }
            return .tokenCount(
                totalOutput: total,
                lastOutput: last,
                timestamp: timestamp,
                ordinal: ordinal
            )
        case "task_started", "turn_started":
            guard let turnID = payload["turn_id"] as? String else { return .ignored }
            return .turnLifecycle(turnID: turnID, timestamp: timestamp, ordinal: ordinal)
        case "task_complete", "turn_complete":
            guard let turnID = payload["turn_id"] as? String else { return .ignored }
            return .turnLifecycle(turnID: turnID, timestamp: timestamp, ordinal: ordinal)
        default:
            return ignoredEventTypes.contains(eventType) ? .ignored : .unknownSchema
        }
    }

    public static func intValue(_ value: Any?) -> Int? {
        switch value {
        case is Bool:
            return nil
        case let value as NSNumber:
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let integer = value.int64Value
            guard value.compare(NSNumber(value: integer)) == .orderedSame else { return nil }
            return Int(exactly: integer)
        default:
            return nil
        }
    }
}

public enum ParsedRolloutLine: Equatable {
    case sessionMeta(id: String, timestamp: String?, ordinal: UInt64?)
    case turnContext(turnID: String?, model: String?, timestamp: String?, ordinal: UInt64?)
    case turnLifecycle(turnID: String, timestamp: String?, ordinal: UInt64?)
    case tokenCount(totalOutput: Int, lastOutput: Int?, timestamp: String?, ordinal: UInt64?)
    case ignored
    case unknownSchema
}

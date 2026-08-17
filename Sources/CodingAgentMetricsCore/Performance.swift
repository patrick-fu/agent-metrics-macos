import Foundation

public enum PerformanceRange: String, Sendable, Equatable, Codable, CaseIterable {
    case fifteenMinutes
    case oneHour
    case twentyFourHours
    case sevenDays

    public var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: 900
        case .oneHour: 3_600
        case .twentyFourHours: 86_400
        case .sevenDays: 604_800
        }
    }

    public var label: String {
        switch self {
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        case .twentyFourHours: "24h"
        case .sevenDays: "7d"
        }
    }
}

public enum DecodeTPSDefinition {
    public static let version = "decode-tps-v1"
    public static let formula = "(output_total - 1) / (duration - ttft)"
}

/// A complete, request-scoped observation.  It deliberately has no content,
/// raw attribute map, endpoint, path, or request body field.
public struct PerformanceFact: Sendable, Equatable, Identifiable {
    public var stableRequestID: String
    public var codingAgent: CodingAgent
    public var model: ModelIdentity
    public var observedAt: Date
    public var durationMilliseconds: Double
    public var ttftMilliseconds: Double
    public var outputTotal: Int
    public var isRetry: Bool
    public var sourceChannel: SourceChannel
    public var authorityTier: AuthorityTier
    public var measurementGranularity: UsageGranularity
    public var measurementRange: DateInterval

    public var id: String { "\(codingAgent.rawValue):\(stableRequestID)" }

    public init(
        stableRequestID: String,
        codingAgent: CodingAgent,
        model: ModelIdentity,
        observedAt: Date,
        durationMilliseconds: Double,
        ttftMilliseconds: Double,
        outputTotal: Int,
        isRetry: Bool,
        sourceChannel: SourceChannel,
        authorityTier: AuthorityTier,
        measurementGranularity: UsageGranularity,
        measurementRange: DateInterval
    ) {
        self.stableRequestID = stableRequestID
        self.codingAgent = codingAgent
        self.model = model
        self.observedAt = observedAt
        self.durationMilliseconds = durationMilliseconds
        self.ttftMilliseconds = ttftMilliseconds
        self.outputTotal = outputTotal
        self.isRetry = isRetry
        self.sourceChannel = sourceChannel
        self.authorityTier = authorityTier
        self.measurementGranularity = measurementGranularity
        self.measurementRange = measurementRange
    }
}

public struct PerformanceDistribution: Sendable, Equatable {
    public var p50: Double?
    public var p95: Double?
    public var p10: Double?
    public var sampleCount: Int
    public var measurementQuality: MeasurementQuality
    public var dataState: DataState?

    public init(values: [Double], quality: MeasurementQuality, includesP10: Bool) {
        let sorted = values.sorted()
        sampleCount = sorted.count
        measurementQuality = sorted.isEmpty ? .unavailable : quality
        dataState = sorted.isEmpty ? .unavailable : nil
        p50 = Self.nearestRank(sorted, percentile: 0.5)
        p95 = Self.nearestRank(sorted, percentile: 0.95)
        p10 = includesP10 ? Self.nearestRank(sorted, percentile: 0.1) : nil
    }

    private static func nearestRank(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        return values[max(0, Int(ceil(percentile * Double(values.count))) - 1)]
    }
}

public enum PerformanceMetricKind: Sendable, Equatable {
    case timeToFirstToken
    case endToEnd
    case decodeTPS
}

public struct PerformanceMetricPresentation: Sendable, Equatable {
    public let valueText: String
    public let secondaryText: String
    public let unitText: String
    public let qualityText: String
    public let lowSampleText: String?
    public let accessibilityHint: String?

    public init(kind: PerformanceMetricKind, distribution: PerformanceDistribution) {
        let isDecode = kind == .decodeTPS
        unitText = isDecode ? "tokens/s" : "ms"
        qualityText = distribution.measurementQuality == .derived ? "Derived" : distribution.measurementQuality.rawValue.capitalized
        valueText = distribution.p50.map(Self.format) ?? "Unavailable"
        let label = isDecode ? "p10" : "p95"
        let secondary = isDecode ? distribution.p10 : distribution.p95
        secondaryText = "p50 · \(label) \(secondary.map(Self.format) ?? "-") · n \(distribution.sampleCount)"
        lowSampleText = (1..<5).contains(distribution.sampleCount) ? "Low sample" : nil
        accessibilityHint = isDecode ? "Derived using \(DecodeTPSDefinition.version): \(DecodeTPSDefinition.formula)." : nil
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

public struct PerformanceSnapshot: Sendable, Equatable {
    public var range: PerformanceRange
    public var timeToFirstToken: PerformanceDistribution
    public var endToEnd: PerformanceDistribution
    public var decodeTPS: PerformanceDistribution
    public var retryCount: Int
    public var invalidDecodeCount: Int
    public var unavailableReason: String?
    public var quantileDefinition: String
}

public struct PerformanceSnapshotBuilder: Sendable {
    public init() {}

    public func build(
        facts: [PerformanceFact],
        now: Date,
        range: PerformanceRange = .oneHour,
        filter: MetricFilter = .all
    ) -> PerformanceSnapshot {
        let start = now.addingTimeInterval(-range.seconds)
        let selected = Self.coalesced(facts).filter {
            $0.observedAt >= start && $0.observedAt <= now && filter.includes($0)
        }
        let normal = selected.filter { !$0.isRetry }
        let ttft = normal.map(\.ttftMilliseconds)
        let e2e = normal.map(\.durationMilliseconds)
        let validDecode = normal.compactMap { fact -> Double? in
            let denominator = fact.durationMilliseconds - fact.ttftMilliseconds
            guard fact.outputTotal >= 2, denominator > 0 else { return nil }
            return Double(fact.outputTotal - 1) / (denominator / 1_000)
        }
        let reason = normal.isEmpty
            ? "Enable loopback OTel request traces; local logs do not contain request-level timings."
            : nil
        return PerformanceSnapshot(
            range: range,
            timeToFirstToken: PerformanceDistribution(values: ttft, quality: .measured, includesP10: false),
            endToEnd: PerformanceDistribution(values: e2e, quality: .measured, includesP10: false),
            decodeTPS: PerformanceDistribution(values: validDecode, quality: .derived, includesP10: true),
            retryCount: selected.filter(\.isRetry).count,
            invalidDecodeCount: normal.count - validDecode.count,
            unavailableReason: reason,
            quantileDefinition: "nearest-rank"
        )
    }

    /// The store normally enforces this invariant.  Keep the snapshot seam
    /// defensive so callers supplying raw facts cannot double-count a request.
    static func coalesced(_ facts: [PerformanceFact]) -> [PerformanceFact] {
        Dictionary(grouping: facts) {
            "\($0.codingAgent.rawValue):\($0.stableRequestID):\($0.measurementGranularity.rawValue)"
        }
        .values
        .compactMap { candidates in
            candidates.reduce(nil) { selected, candidate in
                guard let selected else { return candidate }
                return PerformanceFact.prefers(candidate, over: selected) ? candidate : selected
            }
        }
    }
}

extension PerformanceFact {
    /// Enhanced telemetry is authoritative. Equal-tier conflicts use a stable
    /// total ordering rather than arrival order, and are never summed.
    static func prefers(_ candidate: PerformanceFact, over existing: PerformanceFact) -> Bool {
        if candidate.authorityTier != existing.authorityTier {
            return candidate.authorityTier == .enhanced
        }
        return orderingKey(candidate) < orderingKey(existing)
    }

    private static func orderingKey(_ fact: PerformanceFact) -> String {
        [
            fact.observedAt.timeIntervalSince1970.description,
            fact.durationMilliseconds.description,
            fact.ttftMilliseconds.description,
            String(fact.outputTotal),
            fact.isRetry.description,
            fact.model.raw,
            fact.model.display,
            fact.sourceChannel.rawValue,
            fact.measurementRange.start.timeIntervalSince1970.description,
            fact.measurementRange.end.timeIntervalSince1970.description,
        ].joined(separator: "|")
    }
}

extension MetricFilter {
    func includes(_ fact: PerformanceFact) -> Bool {
        agents.contains(fact.codingAgent.rawValue) && models.contains(fact.model.raw)
    }
}

public enum OTLPReceiverConfigurationError: Error, Sendable, Equatable {
    case nonLoopbackHost(String)
    case nonFixedPort(UInt16)
}

public struct OTLPReceiverConfiguration: Sendable, Equatable {
    public static let fixedHost = "127.0.0.1"
    public static let fixedPort: UInt16 = 4318

    public let isEnabled: Bool
    public let host: String
    public let port: UInt16
    public let endpoint: URL

    public init() {
        isEnabled = false
        host = Self.fixedHost
        port = Self.fixedPort
        endpoint = URL(string: "http://\(Self.fixedHost):\(Self.fixedPort)/v1/traces")!
    }

    public init(enabled: Bool, host: String = OTLPReceiverConfiguration.fixedHost, port: UInt16 = OTLPReceiverConfiguration.fixedPort) throws {
        guard host == Self.fixedHost else {
            throw OTLPReceiverConfigurationError.nonLoopbackHost(host)
        }
        guard port == Self.fixedPort else { throw OTLPReceiverConfigurationError.nonFixedPort(port) }
        isEnabled = enabled
        self.host = Self.fixedHost
        self.port = Self.fixedPort
        endpoint = URL(string: "http://\(Self.fixedHost):\(Self.fixedPort)/v1/traces")!
    }
}

public struct PerformanceIngestionDiagnostic: Sendable, Equatable {
    public var code: String
    public init(code: String) { self.code = code }
}

public struct OTLPDecodeResult: Sendable, Equatable {
    public var facts: [PerformanceFact]
    public var diagnostics: [PerformanceIngestionDiagnostic]
}

/// Only request timing, usage, model and opaque identifiers cross this seam.
/// Raw envelopes are inspected then discarded; sensitive attributes reject the
/// entire batch before any fact is produced.
public struct OTLPHTTPJSONDecoder: Sendable {
    private static let sensitiveFragments = [
        "prompt", "user_prompt", "source code", "source_code", "tool.input", "tool.output", "tool.params",
        "tool.result", "request.body", "response.body", "raw request", "raw_request", "raw response",
        "raw_response", "credential", "authorization", "api_key", "api key", "file.path",
        "file_path", "file.content", "file_content", "message.content", "message_content", "raw_body",
        "path", "content"
    ]
    private static let requiredAttributes: Set<String> = [
        "model", "gen_ai.request.model", "gen_ai.response.model", "duration_ms", "ttft_ms", "output_tokens",
        "gen_ai.usage.output_tokens", "request_id", "gen_ai.response.id", "client_request_id", "attempt"
    ]
    /// Official Claude Code fields which are metadata-only but intentionally
    /// not persisted by this product.
    private static let safeIgnoredAttributes: Set<String> = [
        "span.type", "gen_ai.system", "query_source", "agent_id", "parent_agent_id", "speed",
        "llm_request.context", "input_tokens", "cache_read_tokens", "cache_creation_tokens", "success",
        "status_code", "error", "response.has_tool_call", "stop_reason", "gen_ai.response.finish_reasons",
        "session.id", "app.version", "app.entrypoint", "organization.id", "user.account_uuid", "user.account_id",
        "user.id", "user.email", "terminal.type", "user.groups", "identity.source"
    ]

    public init() {}

    public func decode(_ data: Data, receivedAt: Date) -> OTLPDecodeResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return failure("INVALID_OTLP_JSON")
        }
        guard let resources = object["resourceSpans"] as? [[String: Any]] else { return failure("INVALID_OTLP_JSON") }
        if containsSensitiveAttribute(in: object) { return failure("REJECTED_CONTENT_FIELD") }
        var facts: [PerformanceFact] = []
        for resource in resources {
            guard let scopes = resource["scopeSpans"] as? [[String: Any]] else { return failure("UNSUPPORTED_REQUEST_TRACE") }
            for scope in scopes {
                guard let spans = scope["spans"] as? [[String: Any]] else { return failure("UNSUPPORTED_REQUEST_TRACE") }
                for span in spans {
                    guard span["name"] as? String == "claude_code.llm_request" else { continue }
                    guard let attributes = span["attributes"] as? [[String: Any]] else { return failure("INVALID_REQUEST_FIELDS") }
                    if let failure = targetAttributeFailure(attributes) { return failure }
                    var values: [String: Any] = [:]
                    for attribute in attributes {
                        guard let key = attribute["key"] as? String,
                              let value = scalar(attribute["value"]),
                              values[key] == nil else {
                            return failure("INVALID_REQUEST_FIELDS")
                        }
                        values[key] = value
                    }
                    guard let requestID = string(values, keys: ["request_id", "gen_ai.response.id", "client_request_id"]), !requestID.isEmpty,
                          let model = string(values, keys: ["gen_ai.request.model", "model", "gen_ai.response.model"]), !model.isEmpty,
                          let duration = number(values["duration_ms"]), duration > 0,
                          let ttft = number(values["ttft_ms"]), ttft >= 0, ttft <= duration,
                          let output = integer(values["output_tokens"] ?? values["gen_ai.usage.output_tokens"]), output >= 0,
                          let attempt = integer(values["attempt"]), attempt >= 1 else {
                        return failure("INVALID_REQUEST_FIELDS")
                    }
                    let end = nanoseconds(span["endTimeUnixNano"])
                    let observedAt = end.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) } ?? receivedAt
                    let rangeStart = observedAt.addingTimeInterval(-duration / 1_000)
                    facts.append(PerformanceFact(
                        stableRequestID: requestID,
                        codingAgent: .claudeCode,
                        model: ModelIdentity(raw: model, display: model),
                        observedAt: observedAt,
                        durationMilliseconds: duration,
                        ttftMilliseconds: ttft,
                        outputTotal: output,
                        isRetry: attempt > 1,
                        sourceChannel: .claudeTelemetry,
                        authorityTier: .enhanced,
                        measurementGranularity: .modelCall,
                        measurementRange: DateInterval(start: rangeStart, end: observedAt)
                    ))
                }
            }
        }
        return OTLPDecodeResult(facts: facts, diagnostics: [])
    }

    private func targetAttributeFailure(_ attributes: [[String: Any]]) -> OTLPDecodeResult? {
        for attribute in attributes {
            guard attribute.count == 2, let key = attribute["key"] as? String, attribute["value"] != nil else {
                return failure("REJECTED_UNALLOWLISTED_FIELD")
            }
            if !Self.requiredAttributes.contains(key) && !Self.safeIgnoredAttributes.contains(key) {
                return failure("REJECTED_UNALLOWLISTED_FIELD")
            }
        }
        return nil
    }

    private func containsSensitiveAttribute(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let key = dictionary["key"] as? String, isSensitiveAttributeKey(key) { return true }
            return dictionary.values.contains(where: containsSensitiveAttribute)
        }
        if let array = value as? [Any] { return array.contains(where: containsSensitiveAttribute) }
        return false
    }

    private func isSensitiveAttributeKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if normalized == "code" { return true } // do not match safe `status_code`.
        if normalized == "auth" || normalized.hasPrefix("auth_") || normalized.hasSuffix("_auth") { return true }
        return Self.sensitiveFragments.contains { fragment in
            normalized.contains(
                fragment.replacingOccurrences(of: "-", with: "_")
                    .replacingOccurrences(of: ".", with: "_")
                    .replacingOccurrences(of: " ", with: "_")
            )
        }
    }

    private func string(_ values: [String: Any], keys: [String]) -> String? {
        keys.compactMap { values[$0] as? String }.first
    }

    private func scalar(_ value: Any?) -> Any? {
        guard let dictionary = value as? [String: Any], dictionary.count == 1 else { return nil }
        return dictionary.values.first
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.rounded() == value { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func nanoseconds(_ value: Any?) -> Int64? {
        if let value = value as? String { return Int64(value) }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }

    private func failure(_ code: String) -> OTLPDecodeResult {
        OTLPDecodeResult(facts: [], diagnostics: [PerformanceIngestionDiagnostic(code: code)])
    }
}

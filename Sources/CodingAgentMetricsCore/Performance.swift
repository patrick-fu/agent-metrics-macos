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
        let selected = facts.filter {
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
}

extension MetricFilter {
    func includes(_ fact: PerformanceFact) -> Bool {
        agents.contains(fact.codingAgent.rawValue) && models.contains(fact.model.raw)
    }
}

public enum OTLPReceiverConfigurationError: Error, Sendable, Equatable {
    case nonLoopbackHost(String)
}

public struct OTLPReceiverConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    public var host: String
    public var port: UInt16

    public init() {
        isEnabled = false
        host = "127.0.0.1"
        port = 0
    }

    public init(enabled: Bool, host: String = "127.0.0.1", port: UInt16 = 0) throws {
        guard ["127.0.0.1", "::1"].contains(host) else {
            throw OTLPReceiverConfigurationError.nonLoopbackHost(host)
        }
        isEnabled = enabled
        self.host = host
        self.port = port
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

/// The supported OTLP/HTTP JSON seam is intentionally narrow: one
/// `claude_code.llm_request` span with only the allowlisted attributes below.
/// Anything content-bearing or unknown rejects the entire POST.
public struct OTLPHTTPJSONDecoder: Sendable {
    private static let contentFieldFragments = ["prompt", "tool", "body", "credential", "path", "content", "raw", "code"]
    private static let spanKeys: Set<String> = ["name", "startTimeUnixNano", "endTimeUnixNano", "attributes"]
    private static let allowedSpanAttributes: Set<String> = [
        "request.id", "request_id", "gen_ai.request.model", "model", "duration_ms", "ttft_ms",
        "gen_ai.usage.output_tokens", "output_tokens", "retry_count",
    ]

    public init() {}

    public func decode(_ data: Data, receivedAt: Date) -> OTLPDecodeResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return failure("INVALID_OTLP_JSON")
        }
        guard Set(object.keys) == ["resourceSpans"], let resources = object["resourceSpans"] as? [[String: Any]] else {
            return failure("REJECTED_UNALLOWLISTED_FIELD")
        }
        var facts: [PerformanceFact] = []
        for resource in resources {
            guard Set(resource.keys) == ["resource", "scopeSpans"],
                  let attributes = (resource["resource"] as? [String: Any])?["attributes"] as? [[String: Any]],
                  let service = stringAttribute(attributes, key: "service.name"),
                  ["claude-code", "claude-code-desktop"].contains(service),
                  let scopes = resource["scopeSpans"] as? [[String: Any]] else {
                return failure("UNSUPPORTED_REQUEST_TRACE")
            }
            guard attributes.allSatisfy({ $0.count == 2 && ["key", "value"].allSatisfy($0.keys.contains) && $0["key"] as? String == "service.name" }) else {
                return attributeFailure(attributes) ?? failure("REJECTED_UNALLOWLISTED_FIELD")
            }
            for scope in scopes {
                guard Set(scope.keys) == ["spans"], let spans = scope["spans"] as? [[String: Any]] else {
                    return failure("REJECTED_UNALLOWLISTED_FIELD")
                }
                for span in spans {
                    guard Set(span.keys).isSubset(of: Self.spanKeys),
                          span["name"] as? String == "claude_code.llm_request",
                          let start = nanoseconds(span["startTimeUnixNano"]),
                          let end = nanoseconds(span["endTimeUnixNano"]), end > start,
                          let attributes = span["attributes"] as? [[String: Any]] else {
                        return failure("REJECTED_UNALLOWLISTED_FIELD")
                    }
                    if let failure = attributeFailure(attributes) { return failure }
                    var values: [String: Any] = [:]
                    for attribute in attributes {
                        guard let key = attribute["key"] as? String,
                              let value = scalar(attribute["value"]),
                              values[key] == nil else {
                            return failure("INVALID_REQUEST_FIELDS")
                        }
                        values[key] = value
                    }
                    guard let requestID = string(values, keys: ["request.id", "request_id"]), !requestID.isEmpty,
                          let model = string(values, keys: ["gen_ai.request.model", "model"]), !model.isEmpty,
                          let ttft = number(values["ttft_ms"]), let output = integer(values["gen_ai.usage.output_tokens"] ?? values["output_tokens"]),
                          let retries = integer(values["retry_count"]), ttft >= 0, output >= 0, retries >= 0 else {
                        return failure("INVALID_REQUEST_FIELDS")
                    }
                    let observedAt = Date(timeIntervalSince1970: Double(end) / 1_000_000_000)
                    facts.append(PerformanceFact(
                        stableRequestID: requestID,
                        codingAgent: .claudeCode,
                        model: ModelIdentity(raw: model, display: model),
                        observedAt: observedAt,
                        durationMilliseconds: number(values["duration_ms"]) ?? Double(end - start) / 1_000_000,
                        ttftMilliseconds: ttft,
                        outputTotal: output,
                        isRetry: retries > 0,
                        sourceChannel: .claudeTelemetry,
                        authorityTier: .enhanced,
                        measurementGranularity: .modelCall,
                        measurementRange: DateInterval(start: Date(timeIntervalSince1970: Double(start) / 1_000_000_000), end: observedAt)
                    ))
                }
            }
        }
        return OTLPDecodeResult(facts: facts, diagnostics: [])
    }

    private func attributeFailure(_ attributes: [[String: Any]]) -> OTLPDecodeResult? {
        for attribute in attributes {
            guard attribute.count == 2, let key = attribute["key"] as? String, attribute["value"] != nil else {
                return failure("REJECTED_UNALLOWLISTED_FIELD")
            }
            let lower = key.lowercased()
            if Self.contentFieldFragments.contains(where: lower.contains), !Self.allowedSpanAttributes.contains(key) {
                return failure("REJECTED_CONTENT_FIELD")
            }
            if key != "service.name" && !Self.allowedSpanAttributes.contains(key) {
                return failure("REJECTED_UNALLOWLISTED_FIELD")
            }
        }
        return nil
    }

    private func stringAttribute(_ attributes: [[String: Any]], key: String) -> String? {
        attributes.first { $0["key"] as? String == key }.flatMap { scalar($0["value"]) as? String }
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

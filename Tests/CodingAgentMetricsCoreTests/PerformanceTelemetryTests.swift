import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

struct PerformanceTelemetryTests {
    private let now = Date(timeIntervalSince1970: 1_771_200)

    @Test func receiverDefaultsOffAndOnlyAllowsLoopback() throws {
        #expect(!OTLPReceiverConfiguration().isEnabled)
        #expect(OTLPReceiverConfiguration().host == "127.0.0.1")
        #expect(throws: OTLPReceiverConfigurationError.nonLoopbackHost("0.0.0.0")) {
            try OTLPReceiverConfiguration(enabled: true, host: "0.0.0.0")
        }
    }

    @Test func enabledReceiverBindsAnEphemeralLoopbackPortOnly() throws {
        let configuration = try OTLPReceiverConfiguration(enabled: true, host: "127.0.0.1", port: 0)
        let receiver = OTLPHTTPReceiver(configuration: configuration) { _ in }
        try receiver.start()
        defer { receiver.stop() }
        let deadline = Date().addingTimeInterval(1)
        while receiver.boundPort == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(receiver.isRunning)
        #expect(receiver.boundPort != nil)
        #expect(receiver.configuration.host == "127.0.0.1")
    }

    @Test func decoderRejectsContentAndStoresNoBody() throws {
        let store = try temporaryStore()
        for field in ["prompt", "code", "tool.input", "raw_body", "credential", "path", "content"] {
            let result = OTLPHTTPJSONDecoder().decode(Data(traceJSON(extra: field).utf8), receivedAt: now)
            #expect(result.facts.isEmpty)
            #expect(result.diagnostics.map(\.code) == ["REJECTED_CONTENT_FIELD"])
            try store.upsertPerformanceFacts(result.facts)
        }
        #expect(try store.allPerformanceFacts().isEmpty)
        let columns = try store.performanceFactColumnNames()
        #expect(!columns.contains("payload") && !columns.contains("body"))
    }

    @Test func decoderAcceptsTheMinimalRequestTraceAllowlist() {
        let result = OTLPHTTPJSONDecoder().decode(Data(traceJSON().utf8), receivedAt: now)
        #expect(result.diagnostics.isEmpty)
        #expect(result.facts.count == 1)
        let fact = result.facts[0]
        #expect(fact.stableRequestID == "request-1")
        #expect(fact.codingAgent == .claudeCode)
        #expect(fact.durationMilliseconds == 1_000)
        #expect(fact.ttftMilliseconds == 100)
        #expect(fact.outputTotal == 10)
        #expect(fact.sourceChannel == .claudeTelemetry)
        #expect(fact.authorityTier == .enhanced)
        #expect(fact.measurementGranularity == .modelCall)
    }

    @Test func stableIdentityDeduplicatesAndEnhancedReplacesFallback() throws {
        let store = try temporaryStore()
        var fallback = fact("request-1")
        fallback.sourceChannel = .claudeTranscript
        fallback.authorityTier = .fallback
        fallback.outputTotal = 99
        var enhanced = fact("request-1")
        enhanced.durationMilliseconds = 2_000
        try store.upsertPerformanceFacts([fallback, enhanced])
        let persisted = try store.allPerformanceFacts()
        #expect(persisted.count == 1)
        #expect(persisted[0].authorityTier == .enhanced)
        #expect(persisted[0].outputTotal == 10)
        #expect(persisted[0].durationMilliseconds == 2_000)
    }

    @Test func rangeBoundariesAndNearestRankQuantilesAreExplicit() {
        let facts = [
            fact("1", observedAt: now.addingTimeInterval(-3_600), duration: 100, ttft: 10, output: 11),
            fact("2", observedAt: now.addingTimeInterval(-3_599), duration: 200, ttft: 20, output: 11),
            fact("3", observedAt: now.addingTimeInterval(-10), duration: 300, ttft: 30, output: 11),
            fact("4", observedAt: now.addingTimeInterval(-5), duration: 400, ttft: 40, output: 11),
            fact("5", observedAt: now, duration: 500, ttft: 50, output: 11),
        ]
        let snapshot = PerformanceSnapshotBuilder().build(facts: facts, now: now, range: .oneHour)
        #expect(snapshot.endToEnd.sampleCount == 5)
        #expect(snapshot.endToEnd.p50 == 300 && snapshot.endToEnd.p95 == 500)
        #expect(snapshot.timeToFirstToken.p50 == 30)
        #expect(snapshot.decodeTPS.p50 == 100 / 2.7 && snapshot.decodeTPS.p10 == 100 / 4.5)
        #expect(snapshot.quantileDefinition == "nearest-rank")
    }

    @Test func retriesAndInvalidDecodeAreExcludedButDiagnosed() {
        var retry = fact("retry", observedAt: now)
        retry.isRetry = true
        let invalid = fact("invalid", observedAt: now, duration: 100, ttft: 100)
        let snapshot = PerformanceSnapshotBuilder().build(facts: [retry, invalid], now: now, range: .oneHour)
        #expect(snapshot.endToEnd.sampleCount == 1)
        #expect(snapshot.decodeTPS.sampleCount == 0)
        #expect(snapshot.retryCount == 1 && snapshot.invalidDecodeCount == 1)
        #expect(snapshot.endToEnd.p50 == 100)
    }

    @Test func filtersUseAgentAndModelAndPoolRawSamples() {
        let a1 = fact("a1", observedAt: now, model: "a", duration: 100)
        let a2 = fact("a2", observedAt: now, model: "a", duration: 300)
        let b = fact("b", observedAt: now, model: "b", duration: 9_000)
        var filter = MetricFilter()
        filter.agents.toggle("claude-code")
        filter.models.toggle("a")
        let snapshot = PerformanceSnapshotBuilder().build(facts: [a1, a2, b], now: now, range: .oneHour, filter: filter)
        #expect(snapshot.endToEnd.sampleCount == 2)
        #expect(snapshot.endToEnd.p50 == 100 && snapshot.endToEnd.p95 == 300)
    }

    @Test func unavailableExplainsLocalSourceBoundary() {
        let snapshot = PerformanceSnapshotBuilder().build(facts: [], now: now, range: .oneHour)
        #expect(snapshot.unavailableReason == "Enable loopback OTel request traces; local logs do not contain request-level timings.")
    }

    @Test func oldDatabaseMigratesPerformanceTableAdditively() throws {
        let url = temporaryURL()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE usage_facts (id TEXT PRIMARY KEY, schema_version TEXT NOT NULL, coding_agent_raw TEXT NOT NULL, coding_agent_display TEXT NOT NULL, model_raw TEXT NOT NULL, model_display TEXT NOT NULL, session_id TEXT NOT NULL, turn_id TEXT NOT NULL, observed_at REAL NOT NULL, output_tokens INTEGER NOT NULL, measurement_quality TEXT NOT NULL, authority TEXT NOT NULL, definition_version TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let store = try SQLiteFactStore(url: url)
        try store.upsertPerformanceFacts([fact("request-1")])
        #expect(try store.allFacts().isEmpty)
        #expect(try store.allPerformanceFacts().count == 1)
    }

    @Test func runtimeWiresDefaultOneHourPerformanceSnapshot() throws {
        let runtime = try TelemetryRuntime(storeURL: temporaryURL(), sourceAdapters: [], clock: FixedClock(now: now))
        #expect(!runtime.receiverConfiguration.isEnabled)
        try runtime.ingestPerformance([fact("request-1")])
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.performance.range == .oneHour)
        #expect(snapshot.performance.endToEnd.sampleCount == 1)
    }

    private func fact(_ id: String, observedAt: Date? = nil, model: String = "claude-opus", duration: Double = 1_000, ttft: Double = 100, output: Int = 10) -> PerformanceFact {
        let observedAt = observedAt ?? now
        return PerformanceFact(stableRequestID: id, codingAgent: .claudeCode, model: ModelIdentity(raw: model, display: model), observedAt: observedAt, durationMilliseconds: duration, ttftMilliseconds: ttft, outputTotal: output, isRetry: false, sourceChannel: .claudeTelemetry, authorityTier: .enhanced, measurementGranularity: .modelCall, measurementRange: DateInterval(start: observedAt.addingTimeInterval(-duration / 1_000), end: observedAt))
    }

    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cam-performance-\(UUID().uuidString).sqlite") }
    private func temporaryStore() throws -> SQLiteFactStore { try SQLiteFactStore(url: temporaryURL()) }

    private func traceJSON(extra: String? = nil) -> String {
        let optional = extra.map { ",{\"key\":\"\($0)\",\"value\":{\"stringValue\":\"secret\"}}" } ?? ""
        return """
        {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}}]},"scopeSpans":[{"spans":[{"name":"claude_code.llm_request","startTimeUnixNano":"1771200000000000000","endTimeUnixNano":"1771200001000000000","attributes":[{"key":"request.id","value":{"stringValue":"request-1"}},{"key":"gen_ai.request.model","value":{"stringValue":"claude-opus"}},{"key":"ttft_ms","value":{"doubleValue":100}},{"key":"gen_ai.usage.output_tokens","value":{"intValue":"10"}},{"key":"retry_count","value":{"intValue":"0"}}\(optional)]}]}]}]}
        """
    }
}

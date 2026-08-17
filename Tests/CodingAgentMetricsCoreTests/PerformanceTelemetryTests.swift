import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

@Suite(.serialized)
struct PerformanceTelemetryTests {
    private let now = Date(timeIntervalSince1970: 1_771_200)

    @Test func receiverDefaultsOffAndOnlyAllowsLoopback() throws {
        #expect(!OTLPReceiverConfiguration().isEnabled)
        #expect(OTLPReceiverConfiguration().host == "127.0.0.1")
        #expect(throws: OTLPReceiverConfigurationError.nonLoopbackHost("0.0.0.0")) {
            try OTLPReceiverConfiguration(enabled: true, host: "0.0.0.0")
        }
    }

    @Test func enabledReceiverUsesTheStableLoopbackEndpointOnly() throws {
        let configuration = try OTLPReceiverConfiguration(enabled: true)
        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.port == 4318)
        #expect(configuration.endpoint.absoluteString == "http://127.0.0.1:4318/v1/traces")
        #expect(throws: OTLPReceiverConfigurationError.nonLoopbackHost("0.0.0.0")) {
            try OTLPReceiverConfiguration(enabled: true, host: "0.0.0.0")
        }
        #expect(throws: OTLPReceiverConfigurationError.nonFixedPort(4319)) {
            try OTLPReceiverConfiguration(enabled: true, port: 4319)
        }
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

    @Test func decoderAcceptsOfficialEnvelopeAndIgnoresNonTargetSpans() {
        let result = OTLPHTTPJSONDecoder().decode(Data(officialTraceJSON().utf8), receivedAt: now)
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
        #expect(!fact.isRetry)
    }

    @Test func decoderRejectsSensitiveAttributesAnywhereInTheBatch() {
        let result = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(resourceExtra: "{\"key\":\"message.content\",\"value\":{\"stringValue\":\"secret\"}}").utf8),
            receivedAt: now
        )
        #expect(result.facts.isEmpty)
        #expect(result.diagnostics.map(\.code) == ["REJECTED_CONTENT_FIELD"])
    }

    @Test func decoderRejectsUnknownTargetAttributesButDoesNotMisclassifyStatusCodeAsContent() {
        let accepted = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(targetExtra: "{\"key\":\"success\",\"value\":{\"boolValue\":true}}").utf8),
            receivedAt: now
        )
        #expect(accepted.diagnostics.isEmpty)
        let rejected = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(targetExtra: "{\"key\":\"future.safe_field\",\"value\":{\"stringValue\":\"x\"}}").utf8),
            receivedAt: now
        )
        #expect(rejected.diagnostics.map(\.code) == ["REJECTED_UNALLOWLISTED_FIELD"])
    }

    @Test func decoderRejectsAuthorizationWithoutMisclassifyingAuthorityMetadata() {
        let safe = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(resourceExtra: "{\"key\":\"authority\",\"value\":{\"stringValue\":\"otel\"}}").utf8),
            receivedAt: now
        )
        #expect(safe.diagnostics.isEmpty)
        let rejected = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(resourceExtra: "{\"key\":\"authorization\",\"value\":{\"stringValue\":\"secret\"}}").utf8),
            receivedAt: now
        )
        #expect(rejected.diagnostics.map(\.code) == ["REJECTED_CONTENT_FIELD"])
    }

    @Test func decoderIgnoresOfficialStandardMetadataWithoutPersistingIt() throws {
        let standardAttributes = [
            "{\"key\":\"session.id\",\"value\":{\"stringValue\":\"session-1\"}}",
            "{\"key\":\"app.version\",\"value\":{\"stringValue\":\"2.1.0\"}}",
            "{\"key\":\"app.entrypoint\",\"value\":{\"stringValue\":\"cli\"}}",
            "{\"key\":\"organization.id\",\"value\":{\"stringValue\":\"org-1\"}}",
            "{\"key\":\"user.account_uuid\",\"value\":{\"stringValue\":\"account-uuid\"}}",
            "{\"key\":\"user.account_id\",\"value\":{\"stringValue\":\"account-1\"}}",
            "{\"key\":\"user.id\",\"value\":{\"stringValue\":\"user-1\"}}",
            "{\"key\":\"user.email\",\"value\":{\"stringValue\":\"user@example.com\"}}",
            "{\"key\":\"terminal.type\",\"value\":{\"stringValue\":\"iTerm.app\"}}",
            "{\"key\":\"user.groups\",\"value\":{\"stringValue\":\"engineering\"}}",
            "{\"key\":\"identity.source\",\"value\":{\"stringValue\":\"gateway-oidc\"}}",
        ].joined(separator: ",")
        let result = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(targetExtra: standardAttributes).utf8), receivedAt: now
        )
        #expect(result.diagnostics.isEmpty)
        #expect(result.facts.count == 1)
        let factFields = Set(Mirror(reflecting: result.facts[0]).children.compactMap(\.label))
        #expect(factFields.isDisjoint(with: ["sessionID", "userEmail", "terminalType", "attributeMap"]))
        let store = try temporaryStore()
        try store.upsertPerformanceFacts(result.facts)
        let columns = try store.performanceFactColumnNames()
        #expect(columns.isDisjoint(with: ["session_id", "user_email", "terminal_type", "attribute_map"]))
    }

    @Test func decoderRejectsWorkspaceHostPaths() {
        let result = OTLPHTTPJSONDecoder().decode(
            Data(officialTraceJSON(targetExtra: "{\"key\":\"workspace.host_paths\",\"value\":{\"stringValue\":\"/private/workspace\"}}").utf8),
            receivedAt: now
        )
        #expect(result.facts.isEmpty)
        #expect(result.diagnostics.map(\.code) == ["REJECTED_CONTENT_FIELD"])
    }

    @Test func decoderValidatesAttemptAndTimingConstraints() {
        for (attribute, expected) in [
            ("{\"key\":\"attempt\",\"value\":{\"intValue\":\"0\"}}", "INVALID_REQUEST_FIELDS"),
            ("{\"key\":\"duration_ms\",\"value\":{\"doubleValue\":0}}", "INVALID_REQUEST_FIELDS"),
            ("{\"key\":\"ttft_ms\",\"value\":{\"doubleValue\":1001}}", "INVALID_REQUEST_FIELDS"),
        ] {
            let result = OTLPHTTPJSONDecoder().decode(Data(officialTraceJSON(replacingAttemptWith: attribute).utf8), receivedAt: now)
            #expect(result.diagnostics.map(\.code) == [expected])
        }
    }

    @Test func decoderSupportsOfficialModelAndOpaqueIdentityAliasesAndRetryAttempt() {
        let json = officialTraceJSON()
            .replacingOccurrences(of: "\"key\":\"model\"", with: "\"key\":\"gen_ai.request.model\"")
            .replacingOccurrences(of: "\"key\":\"request_id\"", with: "\"key\":\"gen_ai.response.id\"")
            .replacingOccurrences(of: "\"key\":\"attempt\",\"value\":{\"intValue\":\"1\"}", with: "\"key\":\"attempt\",\"value\":{\"intValue\":\"2\"}")
        let result = OTLPHTTPJSONDecoder().decode(Data(json.utf8), receivedAt: now)
        #expect(result.diagnostics.isEmpty)
        #expect(result.facts[0].model.raw == "claude-opus")
        #expect(result.facts[0].stableRequestID == "request-1")
        #expect(result.facts[0].isRetry)
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

    @Test func enhancedAuthorityWinsRegardlessOfArrivalOrderAndRangeNoise() throws {
        let store = try temporaryStore()
        var fallback = fact("request-1")
        fallback.authorityTier = .fallback
        fallback.sourceChannel = .claudeTranscript
        fallback.measurementRange = DateInterval(start: now.addingTimeInterval(-1.0004), end: now.addingTimeInterval(0.0004))
        var enhanced = fact("request-1")
        enhanced.durationMilliseconds = 2_000
        enhanced.measurementRange = DateInterval(start: now.addingTimeInterval(-2.0001), end: now.addingTimeInterval(0.0001))
        try store.upsertPerformanceFacts([enhanced, fallback])
        #expect(try store.allPerformanceFacts() == [enhanced])

        let snapshot = PerformanceSnapshotBuilder().build(facts: [fallback, enhanced], now: now)
        #expect(snapshot.endToEnd.sampleCount == 1)
        #expect(snapshot.endToEnd.p50 == 2_000)
    }

    @Test func sameTierConflictUsesTheSameDeterministicRepresentativeInEitherOrder() throws {
        var first = fact("request-1", duration: 100)
        var second = fact("request-1", duration: 200)
        first.measurementRange = DateInterval(start: now.addingTimeInterval(-0.1), end: now)
        second.measurementRange = DateInterval(start: now.addingTimeInterval(-0.2), end: now)
        let forward = try temporaryStore()
        let reverse = try temporaryStore()
        try forward.upsertPerformanceFacts([first, second])
        try reverse.upsertPerformanceFacts([second, first])
        let forwardFacts = try forward.allPerformanceFacts()
        let reverseFacts = try reverse.allPerformanceFacts()
        #expect(forwardFacts == reverseFacts)
        #expect(forwardFacts.count == 1)
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

    @Test func performanceRangeExcludesFactsOneSecondBeforeItsStart() {
        let snapshot = PerformanceSnapshotBuilder().build(
            facts: [fact("old", observedAt: now.addingTimeInterval(-3_601))], now: now, range: .oneHour
        )
        #expect(snapshot.endToEnd.sampleCount == 0)
    }

    @Test func receiverReturnsHTTPStatusForAcceptedAndFailedPersistence() async throws {
        let configuration = try OTLPReceiverConfiguration(enabled: true)
        let receiver = OTLPHTTPReceiver(configuration: configuration) { _ in }
        try receiver.start()
        defer { receiver.stop() }
        try await waitUntilRunning(receiver)
        let accepted = try await postTrace(to: configuration.endpoint, body: officialTraceJSON())
        #expect(accepted == 200)
        let rejected = try await postTrace(
            to: configuration.endpoint,
            body: officialTraceJSON(resourceExtra: "{\"key\":\"tool_input\",\"value\":{\"stringValue\":\"secret\"}}")
        )
        #expect(rejected == 400)

        receiver.stop()
        let failing = OTLPHTTPReceiver(configuration: configuration) { _ in throw StoreError.insertFailed }
        try failing.start()
        defer { failing.stop() }
        try await waitUntilRunning(failing)
        let failed = try await postTrace(to: configuration.endpoint, body: officialTraceJSON())
        #expect(failed == 500)
    }

    @Test func receiverSynchronizesRepeatedStartStatusAndStop() throws {
        let configuration = try OTLPReceiverConfiguration(enabled: true)
        let receiver = OTLPHTTPReceiver(configuration: configuration) { _ in }
        defer { receiver.stop() }
        for _ in 0..<4 {
            try receiver.start()
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                _ = receiver.state
                _ = receiver.isRunning
                _ = receiver.boundPort
            }
            #expect(receiver.state == .running)
            #expect(receiver.boundPort == 4318)
            receiver.stop()
            #expect(receiver.state == .stopped)
            #expect(receiver.boundPort == nil)
        }
    }

    @Test func receiverStopCancelsAnInFlightRequestWithoutWaitingForConsume() async throws {
        let enteredConsume = LockedFlag()
        let releaseConsume = DispatchSemaphore(value: 0)
        let configuration = try OTLPReceiverConfiguration(enabled: true)
        let receiver = OTLPHTTPReceiver(configuration: configuration) { _ in
            enteredConsume.set()
            _ = releaseConsume.wait(timeout: .now() + 1)
        }
        try receiver.start()
        defer { receiver.stop() }
        async let response: Int? = try? postTrace(to: configuration.endpoint, body: officialTraceJSON())
        let deadline = Date().addingTimeInterval(1)
        while !enteredConsume.isSet && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(enteredConsume.isSet)
        receiver.stop()
        #expect(receiver.state == .stopped)
        #expect(receiver.boundPort == nil)
        releaseConsume.signal()
        _ = await response
    }

    @Test func runtimeCanEnableAndDisableOnlyItsOwnStableReceiver() async throws {
        let runtime = try TelemetryRuntime(storeURL: temporaryURL(), sourceAdapters: [])
        #expect(runtime.receiverState == .stopped)
        #expect(runtime.receiverEndpoint.absoluteString == "http://127.0.0.1:4318/v1/traces")
        try runtime.setEnhancedTelemetryEnabled(true)
        let deadline = Date().addingTimeInterval(1)
        while runtime.receiverState == .starting && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runtime.receiverState == .running)
        try runtime.setEnhancedTelemetryEnabled(false)
        #expect(runtime.receiverState == .stopped)
    }

    @Test func performancePresentationKeepsUnitsQualityAndLowSampleVisible() {
        let measured = PerformanceDistribution(values: [100, 200], quality: .measured, includesP10: false)
        let timing = PerformanceMetricPresentation(kind: .timeToFirstToken, distribution: measured)
        #expect(timing.unitText == "ms")
        #expect(timing.qualityText == "Measured")
        #expect(timing.secondaryText == "p50 · p95 200 · n 2")
        #expect(timing.lowSampleText == "Low sample")

        let derived = PerformanceDistribution(values: [20], quality: .derived, includesP10: true)
        let decode = PerformanceMetricPresentation(kind: .decodeTPS, distribution: derived)
        #expect(decode.unitText == "tokens/s")
        #expect(decode.qualityText == "Derived")
        #expect(decode.accessibilityHint?.contains(DecodeTPSDefinition.version) == true)
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

    @Test func oldRangeKeyedPerformanceTableMigratesToOneAuthorityAwareRequest() throws {
        let url = temporaryURL()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let sql = """
        CREATE TABLE performance_facts (
            stable_request_id TEXT NOT NULL, coding_agent_raw TEXT NOT NULL, coding_agent_display TEXT NOT NULL,
            model_raw TEXT NOT NULL, model_display TEXT NOT NULL, observed_at REAL NOT NULL, duration_ms REAL NOT NULL,
            ttft_ms REAL NOT NULL, output_total INTEGER NOT NULL, is_retry INTEGER NOT NULL, source_channel TEXT NOT NULL,
            authority_tier TEXT NOT NULL, measurement_granularity TEXT NOT NULL, measurement_range_start REAL NOT NULL,
            measurement_range_end REAL NOT NULL,
            PRIMARY KEY (coding_agent_raw, stable_request_id, measurement_granularity, measurement_range_start, measurement_range_end)
        );
        INSERT INTO performance_facts VALUES
            ('request-1','claude-code','Claude Code','claude-opus','claude-opus',1771200,1000,100,10,0,'claudeTranscript','fallback','modelCall',1771199,1771200),
            ('request-1','claude-code','Claude Code','claude-opus','claude-opus',1771200,2000,100,10,0,'claudeTelemetry','enhanced','modelCall',1771198,1771200);
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let store = try SQLiteFactStore(url: url)
        let facts = try store.allPerformanceFacts()
        #expect(facts.count == 1)
        #expect(facts[0].authorityTier == .enhanced)
        #expect(facts[0].durationMilliseconds == 2_000)
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

    private func officialTraceJSON(
        resourceExtra: String? = nil,
        targetExtra: String? = nil,
        replacingAttemptWith: String? = nil
    ) -> String {
        let resourceExtra = resourceExtra.map { ",\($0)" } ?? ""
        let targetExtra = targetExtra.map { ",\($0)" } ?? ""
        let attempt = replacingAttemptWith ?? "{\"key\":\"attempt\",\"value\":{\"intValue\":\"1\"}}"
        return """
        {"resourceSpans":[{"schemaUrl":"https://opentelemetry.io/schemas/1.24.0","resource":{"schemaUrl":"https://opentelemetry.io/schemas/1.24.0","attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}},{"key":"service.version","value":{"stringValue":"1.0"}}\(resourceExtra)]},"scopeSpans":[{"schemaUrl":"https://opentelemetry.io/schemas/1.24.0","scope":{"name":"claude"},"spans":[{"traceId":"0123456789abcdef0123456789abcdef","spanId":"0123456789abcdef","parentSpanId":"","name":"other.span","kind":1,"startTimeUnixNano":"1771200000000000000","endTimeUnixNano":"1771200001000000000","attributes":[{"key":"unrelated.field","value":{"stringValue":"safe"}}],"status":{"code":0},"events":[],"links":[]},{"traceId":"0123456789abcdef0123456789abcdef","spanId":"fedcba9876543210","parentSpanId":"","name":"claude_code.llm_request","kind":1,"startTimeUnixNano":"1771200000000000000","endTimeUnixNano":"1771200001000000000","attributes":[{"key":"span.type","value":{"stringValue":"llm"}},{"key":"model","value":{"stringValue":"claude-opus"}},{"key":"duration_ms","value":{"doubleValue":1000}},{"key":"ttft_ms","value":{"doubleValue":100}},{"key":"output_tokens","value":{"intValue":"10"}},{"key":"request_id","value":{"stringValue":"request-1"}},\(attempt),{"key":"status_code","value":{"intValue":200}}\(targetExtra)],"status":{"code":0},"events":[],"links":[]}]}]}]}
        """
    }

    private func waitUntilRunning(_ receiver: OTLPHTTPReceiver) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !receiver.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receiver.isRunning)
    }

    private func postTrace(to endpoint: URL, body: String) async throws -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: Data(body.utf8))
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

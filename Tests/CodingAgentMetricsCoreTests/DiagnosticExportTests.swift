import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct DiagnosticExportTests {
    @Test func previewUsesTheFixedAllowlistedSchema() throws {
        let input = DiagnosticExportInput(
            appVersion: "1.2.3",
            buildVersion: "45",
            parserVersions: ["1.2.0", "1.1.0"],
            schemaVersions: ["codex-rollout-v1", "claude-code-transcript-v1"],
            sources: [
                DiagnosticSourceSummary(
                    isHealthy: false,
                    reasonCodes: [.unsupportedSchema, .sourceFailure]
                ),
                DiagnosticSourceSummary(isHealthy: true, reasonCodes: []),
            ],
            metrics: [
                DiagnosticMetricSummary(
                    quality: .derived,
                    coverage: .partial,
                    ageSeconds: 120,
                    reasonCode: .sourceFailure
                ),
                DiagnosticMetricSummary(
                    quality: .measured,
                    coverage: .complete,
                    ageSeconds: 30
                ),
            ]
        )

        let bytes = try DiagnosticExporter().preview(input)

        #expect(String(decoding: bytes, as: UTF8.self) == #"{"coverage_counts":{"complete":1,"partial":1},"metric_count":2,"quality_counts":{"derived":1,"estimated":0,"measured":1,"unavailable":0},"reason_counts":[{"code":"SOURCE_FAILURE","count":2},{"code":"UNSUPPORTED_SCHEMA","count":1}],"relative_age_counts":{"1h_to_24h":0,"1m_to_5m":1,"5m_to_1h":0,"over_24h":0,"under_1m":1,"unknown":0},"schema":"coding-agent-metrics-diagnostics-v1","source_health":{"healthy":1,"unhealthy":1},"sources":[{"health":"healthy","ordinal":1,"reason_codes":[]},{"health":"unhealthy","ordinal":2,"reason_codes":["SOURCE_FAILURE","UNSUPPORTED_SCHEMA"]}],"versions":{"app":"1.2.3","build":"45","parsers":["1.1.0","1.2.0"],"schemas":["claude-code-transcript-v1","codex-rollout-v1"]}}"#)
    }

    @Test func hostileStringsCannotEscapeThroughVersionFields() throws {
        let excluded = [
            "PATH_SECRET_/Users/alice/private",
            "LOCATOR_SECRET_file:///private/source.jsonl",
            "MODEL_SECRET_gpt-customer-alpha",
            "SESSION_SECRET_session-123",
            "TURN_SECRET_turn-456",
            "CALL_SECRET_call-789",
            "REQUEST_SECRET_request-abc",
            "HASH_SECRET_0123456789abcdef",
            "SOURCE_ID_SECRET_source-machine-1",
            "TIMESTAMP_SECRET_2026-08-18T05:04:03Z",
            "URL_SECRET_https://internal.example.invalid/log",
            "MESSAGE_SECRET_raw parser failure",
            "STACK_SECRET_frame0_function_name",
            "CONTENT_SECRET_private prompt and code",
            "TOKEN_SECRET_sk-private-token",
            "BODY_SECRET_{private-request-body}",
            "CREDENTIAL_SECRET_user@example.invalid:password",
        ]
        let input = DiagnosticExportInput(
            appVersion: excluded[0],
            buildVersion: excluded[1],
            parserVersions: Array(excluded[2...9]),
            schemaVersions: Array(excluded[10...]),
            sources: [],
            metrics: []
        )

        let serialized = String(decoding: try DiagnosticExporter().preview(input), as: UTF8.self)

        for hostile in excluded {
            #expect(!serialized.contains(hostile))
        }
    }

    @Test func snapshotMappingDropsPrivateDomainFieldsBeforeSerialization() throws {
        let privateTimestamp = 1_787_018_400
        let privateOutputTokens = 918_273_645
        let privateTokenParts = [91_827_364, 82_736_455, 73_645_546, 64_554_637, 55_463_728]
        let now = Date(timeIntervalSince1970: TimeInterval(privateTimestamp))
        let excluded = [
            "PATH_PRIVATE_USERS_ALICE",
            "LOCATOR_PRIVATE_SOURCE_JSONL",
            "MODEL_PRIVATE_CUSTOMER_ALPHA",
            "SESSION_PRIVATE_123",
            "TURN_PRIVATE_456",
            "CALL_PRIVATE_789",
            "REQUEST_PRIVATE_ABC",
            "HASH_PRIVATE_0123456789",
            "SOURCE_ID_PRIVATE_MACHINE_1",
            "TIMESTAMP_PRIVATE_2026_08_18T05_04_03Z",
            "URL_PRIVATE_INTERNAL_ENDPOINT",
            "MESSAGE_PRIVATE_RAW_FAILURE",
            "STACK_PRIVATE_FRAME_ZERO",
            "CONTENT_PRIVATE_PROMPT_CODE",
            "TOKEN_PRIVATE_API_TOKEN",
            "BODY_PRIVATE_REQUEST_BODY",
            "CREDENTIAL_PRIVATE_ACCOUNT_PASSWORD",
        ]
        let fact = UsageFact(
            id: excluded[7],
            schemaVersion: excluded[15],
            sourceID: excluded[8],
            codingAgent: CodingAgent(rawValue: excluded[0], displayName: excluded[16]),
            model: ModelIdentity(raw: excluded[2], display: excluded[13]),
            sessionID: excluded[3],
            turnID: excluded[4],
            observedAt: now.addingTimeInterval(-30),
            outputTokens: privateOutputTokens,
            measurementQuality: .measured,
            authority: excluded[10],
            definitionVersion: excluded[12],
            tokenParts: TokenParts(
                inputUncached: privateTokenParts[0],
                cacheRead: privateTokenParts[1],
                cacheWrite: privateTokenParts[2],
                outputVisible: privateTokenParts[3],
                reasoning: privateTokenParts[4]
            ),
            modelCallID: excluded[5],
            supersededBy: excluded[6]
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fact], now: now),
            allFacts: [fact],
            now: now,
            sourceHealth: [
                SourceHealth(
                    sourceID: excluded[1],
                    isHealthy: false,
                    diagnosticCode: "SOURCE_FAILURE",
                    impactedAgents: [CodingAgent(rawValue: excluded[11], displayName: excluded[14])]
                ),
            ]
        )
        let input = DiagnosticExportInput(
            snapshot: snapshot,
            appVersion: "1.2.3",
            buildVersion: "45",
            parserVersions: ["1.2.0"],
            schemaVersions: [CodexRolloutParser.schemaVersion]
        )

        let serialized = String(decoding: try DiagnosticExporter().preview(input), as: UTF8.self)

        for hostile in excluded {
            #expect(!serialized.contains(hostile))
        }
        #expect(!serialized.contains(String(privateTimestamp)))
        #expect(!serialized.contains(String(privateOutputTokens)))
        for tokenCount in privateTokenParts {
            #expect(!serialized.contains(String(tokenCount)))
        }
        #expect(serialized.contains(#""SOURCE_FAILURE""#))
        #expect(serialized.contains(#""under_1m":3"#))
    }

    @Test func permutingInputOrderDoesNotChangeSerializedBytes() throws {
        let sources = [
            DiagnosticSourceSummary(isHealthy: false, reasonCodes: [.unsupportedSchema, .sourceFailure]),
            DiagnosticSourceSummary(isHealthy: true, reasonCodes: []),
            DiagnosticSourceSummary(isHealthy: false, reasonCodes: [.capacityHardLimit]),
        ]
        let metrics = [
            DiagnosticMetricSummary(quality: .measured, coverage: .complete, ageSeconds: 20),
            DiagnosticMetricSummary(
                quality: .estimated,
                coverage: .partial,
                ageSeconds: 4_000,
                reasonCode: .retentionPruned
            ),
        ]
        let first = DiagnosticExportInput(
            appVersion: "1.2.3",
            buildVersion: "45",
            parserVersions: ["1.2.0", "1.1.0"],
            schemaVersions: [CodexRolloutParser.schemaVersion, ClaudeTranscriptParser.schemaVersion],
            sources: sources,
            metrics: metrics
        )
        let second = DiagnosticExportInput(
            appVersion: "1.2.3",
            buildVersion: "45",
            parserVersions: ["1.1.0", "1.2.0"],
            schemaVersions: [ClaudeTranscriptParser.schemaVersion, CodexRolloutParser.schemaVersion],
            sources: sources.reversed().map {
                DiagnosticSourceSummary(isHealthy: $0.isHealthy, reasonCodes: Array($0.reasonCodes.reversed()))
            },
            metrics: Array(metrics.reversed())
        )

        #expect(try DiagnosticExporter().preview(first) == DiagnosticExporter().preview(second))
    }
}

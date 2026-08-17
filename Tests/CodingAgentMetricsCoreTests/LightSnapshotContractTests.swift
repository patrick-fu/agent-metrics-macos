import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct LightSnapshotContractTests {
    @Test func emptyStoreIsAbsentUnavailableNotZero() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let sample = LiveSampler().sample(facts: [], now: now)
        let snapshot = SnapshotBuilder().buildLightSnapshot(sample: sample, allFacts: [], now: now)

        #expect(snapshot.outputThroughput.tokensPerSecond == nil)
        #expect(snapshot.outputThroughput.selectedOutputTokens == nil)
        #expect(snapshot.outputThroughput.measurementQuality == .unavailable)
        #expect(snapshot.outputThroughput.dataState == .absent)
        #expect(snapshot.outputThroughput.coverage == .complete)
        #expect(snapshot.outputThroughput.windowSeconds == 180)
    }

    @Test func inWindowZeroTokensIsConfirmedZero() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = makeFact(outputTokens: 0, observedAt: now.addingTimeInterval(-5))
        let sample = LiveSampler().sample(facts: [fact], now: now)
        let snapshot = SnapshotBuilder().buildLightSnapshot(sample: sample, allFacts: [fact], now: now)

        #expect(snapshot.outputThroughput.tokensPerSecond == 0)
        #expect(snapshot.outputThroughput.measurementQuality == .derived)
        #expect(snapshot.outputThroughput.dataState == .zero)
        #expect(snapshot.outputThroughput.coverage == .complete)
    }

    @Test func factsOlderThanWindowAreStaleNotZero() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = makeFact(outputTokens: 900, observedAt: now.addingTimeInterval(-181))
        let sample = LiveSampler().sample(facts: [fact], now: now)
        let snapshot = SnapshotBuilder().buildLightSnapshot(sample: sample, allFacts: [fact], now: now)

        #expect(sample.selectedOutputTokens == 0)
        #expect(snapshot.outputThroughput.tokensPerSecond == nil)
        #expect(snapshot.outputThroughput.measurementQuality == .unavailable)
        #expect(snapshot.outputThroughput.dataState == .stale)
        #expect(snapshot.outputThroughput.coverage == .complete)
    }

    @Test func qualityStateAndCoverageAreIndependentFields() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = makeFact(outputTokens: 180, observedAt: now.addingTimeInterval(-1))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fact], now: now),
            allFacts: [fact],
            now: now
        )
        let metric = snapshot.outputThroughput
        let children = Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: metric).children.compactMap { child in
                child.label.map { ($0, String(describing: type(of: child.value))) }
            }
        )

        #expect(children["measurementQuality"] == "MeasurementQuality")
        #expect(children["dataState"] == "Optional<DataState>")
        #expect(children["coverage"] == "Coverage")
        #expect(metric.measurementQuality == .derived)
        #expect(metric.dataState == nil)
        #expect(metric.coverage == .complete)
        #expect(metric.scope == .all)
        #expect(metric.tokensPerSecond == 1)
        #expect(metric.windowSeconds == 180)
    }

    @Test func presentationSeparatesThroughputFromTPSAndMetadata() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let fact = makeFact(outputTokens: 1800, observedAt: now.addingTimeInterval(-10))
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fact], now: now),
            allFacts: [fact],
            now: now
        )
        let presentation = LightSnapshotPresentation(snapshot: snapshot)

        #expect(presentation.title == "Output Throughput")
        #expect(presentation.windowLabel == "3m")
        #expect(presentation.valueText == "10")
        #expect(presentation.unitText == "tokens/s")
        #expect(presentation.qualityText == "Derived")
        #expect(presentation.dataStateText == "-")
        #expect(presentation.coverageText == "Complete")
        #expect(presentation.agentChips == [FilterChip(id: "all", title: "All", isSelected: true)])
        #expect(presentation.modelChips == [FilterChip(id: "all", title: "All", isSelected: true)])
        #expect(!presentation.title.localizedCaseInsensitiveContains("TPS"))
        #expect(!presentation.unitText.localizedCaseInsensitiveContains("TPS"))
        #expect(!presentation.valueText.localizedCaseInsensitiveContains("Decode"))
    }

    @Test func runtimeBuildsLightSnapshotFromSyntheticFixture() throws {
        let clock = FixedClock(now: Date(timeIntervalSince1970: 1_771_200))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            fixtureURL: FixtureLocator.syntheticCodexTokenCountV1,
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.tokensPerSecond == 10)
        #expect(snapshot.outputThroughput.measurementQuality == .derived)
        #expect(snapshot.outputThroughput.dataState == nil)
        #expect(snapshot.outputThroughput.coverage == .complete)
    }

    @Test func runtimeAcceptsAStableSourceAdapterSeam() throws {
        let clock = FixedClock(now: Date(timeIntervalSince1970: 1_771_200))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-adapter-seam-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let observation = UsageObservation(
            observationIdentity: "test-observation-001",
            schemaVersion: "test-adapter-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: "gpt-synthetic-orion", display: "Synthetic Orion"),
            sessionID: "syn-session-002",
            turnID: "syn-turn-002",
            observedAt: clock.now.addingTimeInterval(-1),
            outputTokens: 360
        )

        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: FixedSourceAdapter(observations: [observation]),
            clock: clock
        )

        #expect(try runtime.lightSnapshot().outputThroughput.tokensPerSecond == 2)
    }

    @Test func appIdentityAndPopoverWidthAreFrozen() throws {
        #expect(AppIdentity.bundleIdentifier == "dev.codingagentmetrics.app")
        #expect((420...440).contains(AppIdentity.popoverWidth))
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodingAgentMetricsApp/Info.plist")
        let text = try String(contentsOf: plist, encoding: .utf8)
        #expect(text.contains("<string>dev.codingagentmetrics.app</string>"))
        #expect(text.contains("<key>LSUIElement</key>"))
    }

    private func makeFact(outputTokens: Int, observedAt: Date) -> UsageFact {
        UsageFact(
            id: "fact-\(outputTokens)-\(observedAt.timeIntervalSince1970)",
            schemaVersion: "synthetic-codex-token-count-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: "gpt-synthetic-orion", display: "Synthetic Orion"),
            sessionID: "syn-session-001",
            turnID: "syn-turn-001",
            observedAt: observedAt,
            outputTokens: outputTokens,
            measurementQuality: .measured,
            authority: "synthetic-codex-token-count",
            definitionVersion: OutputThroughputDefinition.version
        )
    }

    private struct FixedSourceAdapter: SourceAdapter {
        let observations: [UsageObservation]

        func loadObservations(clock: any Clock) throws -> [UsageObservation] {
            observations
        }
    }
}

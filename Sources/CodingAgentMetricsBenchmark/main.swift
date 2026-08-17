import CodingAgentMetricsCore
import Dispatch
import Foundation

private let factCount = TelemetryRuntime.maximumQueryFacts
private let sampleCount = max(1, Int(CommandLine.arguments.dropFirst().first ?? "100") ?? 100)
private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let fileManager = FileManager.default
private let directory = fileManager.temporaryDirectory
    .appendingPathComponent("coding-agent-metrics-benchmark-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: directory) }

let storeURL = directory.appendingPathComponent("synthetic.sqlite")
let store = try SQLiteFactStore(url: storeURL)
let facts = (0..<factCount).map { index -> UsageFact in
    let observedAt = now.addingTimeInterval(-599 + 599 * Double(index) / Double(factCount - 1))
    let modelIndex = index % 6
    return UsageFact(
        id: "synthetic-fact-\(index)",
        schemaVersion: "synthetic-benchmark-v1",
        sourceID: index.isMultiple(of: 2) ? "synthetic-codex" : "synthetic-claude",
        codingAgent: index.isMultiple(of: 2) ? .codex : .claudeCode,
        model: ModelIdentity(raw: "synthetic-model-\(modelIndex)", display: "Synthetic Model \(modelIndex)"),
        sessionID: "synthetic-session-\(index % 32)",
        turnID: "synthetic-turn-\(index)",
        observedAt: observedAt,
        outputTokens: (index % 19) + 1,
        measurementQuality: .measured,
        authority: "synthetic-benchmark",
        definitionVersion: "synthetic-benchmark-v1",
        tokenParts: TokenParts(
            inputUncached: 2,
            cacheRead: 1,
            cacheWrite: 0,
            outputVisible: (index % 19) + 1,
            reasoning: 0
        ),
        modelCallID: "synthetic-call-\(index)",
        modelCallCapability: .available,
        sourceChannel: .synthetic,
        authorityTier: .fallback,
        measurementGranularity: .modelCall,
        measurementRange: DateInterval(start: observedAt, end: observedAt)
    )
}
try store.upsert(facts)

let runtime = try TelemetryRuntime(storeURL: storeURL, sourceAdapters: [], clock: FixedClock(now: now))
for _ in 0..<5 {
    _ = try runtime.lightSnapshotFromStore(filter: .all)
    _ = try runtime.trendSnapshot()
}

func measure(count: Int = sampleCount, _ operation: () throws -> Void) rethrows -> LatencyStatistics {
    var samples: [Double] = []
    samples.reserveCapacity(count)
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        let end = DispatchTime.now().uptimeNanoseconds
        samples.append(Double(end - start) / 1_000_000)
    }
    return LatencyStatistics(samplesMilliseconds: samples)
}

let light = try measure { _ = try runtime.lightSnapshotFromStore(filter: .all) }
let detail = try measure { _ = try runtime.trendSnapshot() }
let profileSamples = min(sampleCount, 30)
let interval = DateInterval(start: now.addingTimeInterval(-600), end: now)
let query = try measure(count: profileSamples) {
    _ = try store.factWindow(in: interval, limit: TelemetryRuntime.maximumQueryFacts)
}
let loadedFacts = try store.factWindow(in: interval, limit: TelemetryRuntime.maximumQueryFacts).rows
let lightBuild = measure(count: profileSamples) {
    let sample = LiveSampler().sample(facts: loadedFacts, now: now)
    _ = SnapshotBuilder().buildLightSnapshot(sample: sample, allFacts: loadedFacts, now: now)
}
let detailBuild = measure(count: profileSamples) {
    _ = TrendBuilder().build(facts: loadedFacts, now: now)
}

func format(_ value: Double?) -> String {
    value.map { String(format: "%.3f", $0) } ?? "not-measured"
}

print("workload=synthetic Swift+SQLite runtime snapshots; facts=\(factCount); models=6; samples=\(sampleCount); warmups=5; build=release")
print("light p50_ms=\(format(light.p50Milliseconds)) p95_ms=\(format(light.p95Milliseconds)) max_ms=\(format(light.maximumMilliseconds)) reference_ms=5 outcome=\(light.outcome(candidateReferenceMilliseconds: 5).rawValue)")
print("detail p50_ms=\(format(detail.p50Milliseconds)) p95_ms=\(format(detail.p95Milliseconds)) max_ms=\(format(detail.maximumMilliseconds)) reference_ms=16 outcome=\(detail.outcome(candidateReferenceMilliseconds: 16).rawValue)")
print("profile samples=\(profileSamples) sqlite_query_p50_ms=\(format(query.p50Milliseconds)) sqlite_query_p95_ms=\(format(query.p95Milliseconds)) light_builder_p50_ms=\(format(lightBuild.p50Milliseconds)) light_builder_p95_ms=\(format(lightBuild.p95Milliseconds)) trend_builder_p50_ms=\(format(detailBuild.p50Milliseconds)) trend_builder_p95_ms=\(format(detailBuild.p95Milliseconds))")
print("appkit_rendering=not-measured")

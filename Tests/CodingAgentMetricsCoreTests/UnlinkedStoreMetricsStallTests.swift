import Foundation
import Testing
@testable import CodingAgentMetricsCore

/// Red-capable loop for "source still growing, menu metrics stop updating".
///
/// Live 0.2.0 holds an unlinked `facts.sqlite` while Codex rollouts keep
/// appending. This test asks TelemetryRuntime to keep ingesting after the
/// store directory is removed from the filesystem namespace.
struct UnlinkedStoreMetricsStallTests {
    @Test func growingRolloutUpdatesLightSnapshotBeforeUnlink() throws {
        let env = try StallFixture()
        defer { env.tearDown() }

        let first = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(first.outputThroughput.selectedOutputTokens == 1_800)
        #expect(LightSnapshotPresentation(snapshot: first).menuBarTitleText == "10 t/s")

        try env.append(totalOutput: 2_700, lastOutput: 900, timestamp: "2026-04-15T12:00:12.000Z", ordinal: 4)
        let second = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(second.outputThroughput.selectedOutputTokens == 2_700)
        #expect(LightSnapshotPresentation(snapshot: second).menuBarTitleText == "15 t/s")
    }

    @Test func unlinkedStoreDirectoryStillIngestsGrowingRollout() throws {
        let env = try StallFixture()
        defer { env.tearDown() }

        let first = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(first.outputThroughput.selectedOutputTokens == 1_800)
        #expect(LightSnapshotPresentation(snapshot: first).menuBarTitleText == "10 t/s")

        try FileManager.default.removeItem(at: env.storeDirectory)
        #expect(!FileManager.default.fileExists(atPath: env.storeURL.path))

        try env.append(totalOutput: 3_600, lastOutput: 1_800, timestamp: "2026-04-15T12:00:14.000Z", ordinal: 4)
        let second = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(FileManager.default.fileExists(atPath: env.storeURL.path))
        #expect(second.outputThroughput.selectedOutputTokens == 3_600)
        #expect(LightSnapshotPresentation(snapshot: second).menuBarTitleText == "20 t/s")
        #expect(second.outputThroughput.dataState != .stale)

        try env.append(totalOutput: 4_500, lastOutput: 900, timestamp: "2026-04-15T12:00:16.000Z", ordinal: 5)
        let third = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(third.outputThroughput.selectedOutputTokens == 4_500)
        #expect(LightSnapshotPresentation(snapshot: third).menuBarTitleText == "25 t/s")
        #expect(third.outputThroughput.dataState != .stale)
    }

    @Test func unlinkedStoreFromStoreRebuildsInsteadOfPublishingZeros() throws {
        let env = try StallFixture()
        defer { env.tearDown() }

        let first = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(first.outputThroughput.selectedOutputTokens == 1_800)

        try FileManager.default.removeItem(at: env.storeDirectory)
        try env.append(totalOutput: 3_600, lastOutput: 1_800, timestamp: "2026-04-15T12:00:14.000Z", ordinal: 4)

        let stored = try env.runtime.lightSnapshotFromStore(
            filter: .all,
            windowSeconds: 180
        )
        #expect(FileManager.default.fileExists(atPath: env.storeURL.path))
        #expect(stored.outputThroughput.selectedOutputTokens == 3_600)
        #expect(LightSnapshotPresentation(snapshot: stored).menuBarTitleText == "20 t/s")
        #expect(stored.outputThroughput.dataState != .stale)
    }

    @Test func replacedDatabaseFileStillRebuildsFromSources() throws {
        let env = try StallFixture()
        defer { env.tearDown() }

        let first = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(first.outputThroughput.selectedOutputTokens == 1_800)

        let fm = FileManager.default
        try fm.removeItem(at: env.storeURL)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: env.storeURL.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try fm.removeItem(at: sidecar)
            }
        }
        let replacement = try SQLiteFactStore(url: env.storeURL)
        #expect(try replacement.allFacts().isEmpty)
        #expect(fm.fileExists(atPath: env.storeURL.path))

        try env.append(totalOutput: 3_600, lastOutput: 1_800, timestamp: "2026-04-15T12:00:14.000Z", ordinal: 4)
        let stored = try env.runtime.lightSnapshotFromStore(
            filter: .all,
            windowSeconds: 180
        )
        #expect(stored.outputThroughput.selectedOutputTokens == 3_600)
        #expect(LightSnapshotPresentation(snapshot: stored).menuBarTitleText == "20 t/s")
        #expect(stored.outputThroughput.dataState != .stale)
    }

    @Test func unlinkedDatabaseFileWithOrphanSidecarsStillRebuilds() throws {
        let env = try StallFixture()
        defer { env.tearDown() }

        let first = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(first.outputThroughput.selectedOutputTokens == 1_800)

        try FileManager.default.removeItem(at: env.storeURL)
        #expect(FileManager.default.fileExists(atPath: env.storeDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: env.storeURL.path))
        let wal = URL(fileURLWithPath: env.storeURL.path + "-wal")
        let shm = URL(fileURLWithPath: env.storeURL.path + "-shm")
        try Data(repeating: 0x61, count: 4_096).write(to: wal)
        try Data(repeating: 0x62, count: 32_768).write(to: shm)

        try env.append(totalOutput: 3_600, lastOutput: 1_800, timestamp: "2026-04-15T12:00:14.000Z", ordinal: 4)
        let second = try env.runtime.lightSnapshot(windowSeconds: 180)
        #expect(FileManager.default.fileExists(atPath: env.storeURL.path))
        #expect(second.outputThroughput.selectedOutputTokens == 3_600)
        #expect(LightSnapshotPresentation(snapshot: second).menuBarTitleText == "20 t/s")
        #expect(second.outputThroughput.dataState != .stale)
    }
}

private final class StallFixture {
    let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
    let homeRoot: URL
    let storeDirectory: URL
    let storeURL: URL
    let runtime: TelemetryRuntime
    private let activeURL: URL

    init() throws {
        let fm = FileManager.default
        homeRoot = fm.temporaryDirectory.appendingPathComponent("cam-stall-home-\(UUID().uuidString)", isDirectory: true)
        storeDirectory = fm.temporaryDirectory.appendingPathComponent("cam-stall-store-\(UUID().uuidString)", isDirectory: true)
        storeURL = storeDirectory.appendingPathComponent("facts.sqlite")
        let activeDirectory = homeRoot.appendingPathComponent("sessions/2026/04/15", isDirectory: true)
        try fm.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        activeURL = activeDirectory.appendingPathComponent(
            "rollout-2026-04-15T12-00-00-01900000-0000-7000-8000-000000000013.jsonl"
        )
        let initial = [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1_800, lastOutput: 1_800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ]
        try (initial.joined(separator: "\n") + "\n").write(to: activeURL, atomically: true, encoding: .utf8)
        runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: homeRoot),
            clock: clock
        )
    }

    func append(totalOutput: Int, lastOutput: Int, timestamp: String, ordinal: Int) throws {
        let handle = try FileHandle(forWritingTo: activeURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(tokenCountLine(totalOutput: totalOutput, lastOutput: lastOutput, timestamp: timestamp, ordinal: ordinal))\n".utf8))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: homeRoot)
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
    }

    private func writeRollout(lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: activeURL, atomically: true, encoding: .utf8)
    }
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}

private func sessionMetaLine() -> String {
    """
    {"timestamp":"2026-04-15T12:00:00.000Z","ordinal":1,"type":"session_meta","payload":{"session_id":"01900000-0000-7000-8000-000000000013","id":"01900000-0000-7000-8000-000000000013","timestamp":"2026-04-15T12:00:00.000Z","cwd":"/tmp/synthetic-codex-workspace","originator":"codex-cli","cli_version":"0.145.0","source":"cli","model_provider":"openai"}}
    """
}

private func turnContextLine() -> String {
    """
    {"timestamp":"2026-04-15T12:00:01.000Z","ordinal":2,"type":"turn_context","payload":{"turn_id":"01900000-0000-7000-8000-000000000113","cwd":"/tmp/synthetic-codex-workspace","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"model":"gpt-synthetic-orion","summary":"auto"}}
    """
}

private func tokenCountLine(totalOutput: Int, lastOutput: Int, timestamp: String, ordinal: Int) -> String {
    """
    {"timestamp":"\(timestamp)","ordinal":\(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":3000,"cache_write_input_tokens":800,"output_tokens":\(totalOutput),"reasoning_output_tokens":400,"total_tokens":6800},"last_token_usage":{"input_tokens":5000,"cached_input_tokens":3000,"cache_write_input_tokens":800,"output_tokens":\(lastOutput),"reasoning_output_tokens":400,"total_tokens":6800},"model_context_window":128000},"rate_limits":null}}
    """
}

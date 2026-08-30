import AppKit
import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import Foundation
import SwiftUI

enum AppLaunchMode: Equatable {
    case application
    case renderBenchmark(sampleCount: Int)
    case snapshotSummary(outputPath: String, mutateOnePixel: Bool)
    case snapshotSurface(surface: SnapshotSurface, appearance: SnapshotAppearance, outputPath: String, mutateOnePixel: Bool)
    case snapshotContactSheet(appearance: SnapshotAppearance, outputPath: String)
    case invalidBenchmarkArguments
    case invalidSnapshotArguments
}

enum AppCommandLine {
    static func mode(arguments: [String]) -> AppLaunchMode {
        switch arguments.first {
        case "--benchmark-render":
            guard arguments.count == 2,
                  let sampleCount = Int(arguments[1]),
                  sampleCount > 0 else { return .invalidBenchmarkArguments }
            return .renderBenchmark(sampleCount: sampleCount)
        case "--snapshot-summary":
            guard arguments.count >= 2 else { return .invalidSnapshotArguments }
            return .snapshotSummary(
                outputPath: arguments[1],
                mutateOnePixel: arguments.contains("--mutate-one-pixel")
            )
        case "--snapshot-surface":
            guard arguments.count == 4 || arguments.count == 5,
                  let surface = SnapshotSurface(rawValue: arguments[1]),
                  let appearance = SnapshotAppearance(rawValue: arguments[2]),
                  arguments.count == 4 || arguments[4] == "--mutate-one-pixel" else {
                return .invalidSnapshotArguments
            }
            return .snapshotSurface(
                surface: surface,
                appearance: appearance,
                outputPath: arguments[3],
                mutateOnePixel: arguments.contains("--mutate-one-pixel")
            )
        case "--snapshot-contact-sheet":
            guard arguments.count == 3,
                  let appearance = SnapshotAppearance(rawValue: arguments[1]) else {
                return .invalidSnapshotArguments
            }
            return .snapshotContactSheet(appearance: appearance, outputPath: arguments[2])
        default:
            return .application
        }
    }
}

enum AppRenderBenchmarkError: Error {
    case renderSurfaceUnavailable
}

@MainActor
enum AppRenderBenchmark {
    static let defaultWarmupCount = 5

    static func measure(
        sampleCount: Int,
        warmupCount: Int = defaultWarmupCount
    ) throws -> LatencyStatistics {
        precondition(sampleCount > 0)
        precondition(warmupCount >= 0)
        _ = NSApplication.shared
        let snapshot = syntheticSnapshot()
        let services = AppLifecycleServices(
            launchAtLogin: LaunchAtLoginController(service: BenchmarkLaunchAtLoginService()),
            updates: UpdateCheckController(service: BenchmarkUpdateService())
        )
        let defaults = UserDefaults(suiteName: "dev.codingagentmetrics.render-benchmark") ?? .standard
        defaults.setVolatileDomain(
            [EnhancedTelemetryController.defaultsKey: false],
            forName: "dev.codingagentmetrics.render-benchmark"
        )
        let telemetry = EnhancedTelemetryController(runtime: nil, defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppIdentity.popoverWidth, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        for _ in 0..<warmupCount {
            try render(snapshot: snapshot, services: services, telemetry: telemetry, in: window)
        }
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                try render(snapshot: snapshot, services: services, telemetry: telemetry, in: window)
            }
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        return LatencyStatistics(samplesMilliseconds: samples)
    }

    static func report(statistics: LatencyStatistics, warmupCount: Int = defaultWarmupCount) -> String {
        [
            "workload=synthetic AppKit+SwiftUI SummaryPopoverView composition+layout+bitmap-render; samples=\(statistics.sampleCount); warmups=\(warmupCount); build=release",
            "appkit_render p50_ms=\(format(statistics.p50Milliseconds)) p95_ms=\(format(statistics.p95Milliseconds)) max_ms=\(format(statistics.maximumMilliseconds))",
        ].joined(separator: "\n")
    }

    private static func render(
        snapshot: LightSnapshot,
        services: AppLifecycleServices,
        telemetry: EnhancedTelemetryController,
        in window: NSWindow
    ) throws {
        let root = SummaryPopoverView(
            snapshot: snapshot,
            lifecycleServices: services,
            telemetry: telemetry
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: AppIdentity.popoverWidth, height: 720)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize
        hosting.frame.size = NSSize(
            width: AppIdentity.popoverWidth,
            height: max(240, fittingSize.height)
        )
        window.setContentSize(hosting.frame.size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppRenderBenchmarkError.renderSurfaceUnavailable
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    }

    private static func syntheticSnapshot() -> LightSnapshot {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let facts = (0..<12).map { index -> UsageFact in
            let observedAt = now.addingTimeInterval(-Double(index + 1))
            return UsageFact(
                id: "synthetic-render-fact-\(index)",
                schemaVersion: "synthetic-render-v1",
                sourceID: index.isMultiple(of: 2) ? "synthetic-codex" : "synthetic-claude",
                codingAgent: index.isMultiple(of: 2) ? .codex : .claudeCode,
                model: ModelIdentity(
                    raw: "synthetic-model-\(index % 3)",
                    display: "Synthetic Model \(index % 3)"
                ),
                sessionID: "synthetic-session-\(index % 2)",
                turnID: "synthetic-turn-\(index)",
                observedAt: observedAt,
                outputTokens: 100 + index,
                measurementQuality: .measured,
                authority: "synthetic-render",
                definitionVersion: "synthetic-render-v1",
                tokenParts: TokenParts(
                    inputUncached: 20,
                    cacheRead: 10,
                    cacheWrite: 0,
                    outputVisible: 100 + index,
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
        return SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, now: now),
            allFacts: facts,
            now: now
        )
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "not-measured"
    }
}

@MainActor
private final class BenchmarkLaunchAtLoginService: LaunchAtLoginService {
    func registrationStatus() -> LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class BenchmarkUpdateService: UpdateCheckingService {
    func checkForUpdates() {}
}

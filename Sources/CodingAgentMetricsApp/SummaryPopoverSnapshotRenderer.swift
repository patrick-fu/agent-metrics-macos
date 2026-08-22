import AppKit
import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import Foundation
import SwiftUI

enum SummaryPopoverSnapshotRendererError: Error {
    case renderSurfaceUnavailable
    case pngEncodingFailed
}

struct SnapshotPixelComparison: Equatable, Sendable {
    var width: Int
    var height: Int
    var expectedWidth: Int
    var expectedHeight: Int
    var changedPixelCount: Int
    var maxChannelDelta: Int
    var matches: Bool
}

enum SummaryPopoverPixelComparator {
    static let maximumChangedPixels = 64
    static let maximumChannelDelta = 12

    static func compare(actual: NSBitmapImageRep, expected: NSBitmapImageRep) -> SnapshotPixelComparison {
        let width = actual.pixelsWide
        let height = actual.pixelsHigh
        let expectedWidth = expected.pixelsWide
        let expectedHeight = expected.pixelsHigh
        guard width == expectedWidth, height == expectedHeight else {
            return SnapshotPixelComparison(
                width: width,
                height: height,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                changedPixelCount: width * height,
                maxChannelDelta: 255,
                matches: false
            )
        }
        guard let actualBytes = actual.bitmapData,
              let expectedBytes = expected.bitmapData,
              actual.bitsPerSample == 8,
              expected.bitsPerSample == 8,
              actual.samplesPerPixel == expected.samplesPerPixel,
              actual.samplesPerPixel >= 3 else {
            return SnapshotPixelComparison(
                width: width,
                height: height,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                changedPixelCount: width * height,
                maxChannelDelta: 255,
                matches: false
            )
        }
        let channels = actual.samplesPerPixel
        var changed = 0
        var maxDelta = 0
        for y in 0..<height {
            let actualRow = y * actual.bytesPerRow
            let expectedRow = y * expected.bytesPerRow
            for x in 0..<width {
                let actualPixel = actualRow + x * channels
                let expectedPixel = expectedRow + x * channels
                var pixelDelta = 0
                for index in 0..<channels {
                    pixelDelta = max(pixelDelta, abs(Int(actualBytes[actualPixel + index]) - Int(expectedBytes[expectedPixel + index])))
                }
                if pixelDelta > 0 {
                    changed += 1
                    maxDelta = max(maxDelta, pixelDelta)
                }
            }
        }
        return SnapshotPixelComparison(
            width: width,
            height: height,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            changedPixelCount: changed,
            maxChannelDelta: maxDelta,
            matches: changed <= maximumChangedPixels && maxDelta <= maximumChannelDelta
        )
    }

    static func diffImage(actual: NSBitmapImageRep, expected: NSBitmapImageRep) -> NSBitmapImageRep? {
        let width = max(actual.pixelsWide, expected.pixelsWide)
        let height = max(actual.pixelsHigh, expected.pixelsHigh)
        guard let actualBytes = actual.bitmapData,
              let expectedBytes = expected.bitmapData,
              actual.bitsPerSample == 8,
              expected.bitsPerSample == 8,
              actual.samplesPerPixel == expected.samplesPerPixel,
              actual.samplesPerPixel >= 3 else { return nil }
        guard let diff = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        guard let diffBytes = diff.bitmapData else { return nil }
        let channels = actual.samplesPerPixel
        for y in 0..<height {
            for x in 0..<width {
                let diffOffset = y * diff.bytesPerRow + x * diff.samplesPerPixel
                let inActual = x < actual.pixelsWide && y < actual.pixelsHigh
                let inExpected = x < expected.pixelsWide && y < expected.pixelsHigh
                if !inActual || !inExpected {
                    write([255, 0, 255, 255], to: diffBytes, at: diffOffset)
                    continue
                }
                let actualOffset = y * actual.bytesPerRow + x * channels
                let expectedOffset = y * expected.bytesPerRow + x * channels
                var delta = 0
                for index in 0..<channels {
                    delta = max(delta, abs(Int(actualBytes[actualOffset + index]) - Int(expectedBytes[expectedOffset + index])))
                }
                write(delta == 0 ? [0, 0, 0, 255] : [255, 0, 0, 255], to: diffBytes, at: diffOffset)
            }
        }
        return diff
    }

    static func mutateOnePixel(_ bitmap: NSBitmapImageRep) {
        guard let bytes = bitmap.bitmapData, bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3 else { return }
        let x = bitmap.pixelsWide / 2
        let y = bitmap.pixelsHigh / 2
        let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
        bytes[offset] ^= 0xFF
    }

    private static func write(_ rgba: [UInt8], to bytes: UnsafeMutablePointer<UInt8>, at offset: Int) {
        for index in 0..<4 {
            bytes[offset + index] = rgba[index]
        }
    }
}

@MainActor
enum SummaryPopoverSnapshotRenderer {
    static let pointWidth = AppIdentity.popoverWidth
    static let scale: CGFloat = 2
    static let now = Date(timeIntervalSince1970: 1_771_200)

    static func renderBitmap(mutateOnePixel: Bool = false) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let light = syntheticLightSnapshot()
        let trends = TrendBuilder().build(facts: syntheticFacts(), now: now, sourceHealth: syntheticSourceHealth)
        let snapshots = RuntimeSnapshots(light: light, detail: trends)
        let suite = "dev.codingagentmetrics.snapshot-renderer"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: EnhancedTelemetryController.defaultsKey)
        let preferences = DisplayPreferencesController(store: DisplayPreferencesStore(defaults: defaults))
        preferences.window = .threeMinutes
        preferences.cadence = .thirtySeconds
        let services = AppLifecycleServices(
            launchAtLogin: LaunchAtLoginController(service: SnapshotLaunchAtLoginService()),
            updates: UpdateCheckController(service: SnapshotUpdateService())
        )
        let telemetry = EnhancedTelemetryController(runtime: nil, defaults: defaults)
        let root = SummaryPopoverView(
            snapshot: light,
            snapshots: snapshots,
            lifecycleServices: services,
            telemetry: telemetry,
            preferences: preferences,
            clock: FixedClock(now: now)
        )
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.calendar, Calendar(identifier: .gregorian))
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .environment(\.colorScheme, .light)
        .transaction { $0.animation = nil }

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: pointWidth, height: 720)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: pointWidth, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let height = max(240, hosting.fittingSize.height)
        hosting.frame.size = NSSize(width: pointWidth, height: height)
        window.setContentSize(hosting.frame.size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let pixelWidth = Int(pointWidth * scale)
        let pixelHeight = Int((height * scale).rounded(.up))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SummaryPopoverSnapshotRendererError.renderSurfaceUnavailable
        }
        bitmap.size = NSSize(width: pointWidth, height: height)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        if mutateOnePixel {
            SummaryPopoverPixelComparator.mutateOnePixel(bitmap)
        }
        return bitmap
    }

    static func renderPNG(mutateOnePixel: Bool = false) throws -> Data {
        let bitmap = try renderBitmap(mutateOnePixel: mutateOnePixel)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SummaryPopoverSnapshotRendererError.pngEncodingFailed
        }
        return data
    }

    static func writePNG(to url: URL, mutateOnePixel: Bool = false) throws {
        try renderPNG(mutateOnePixel: mutateOnePixel).write(to: url, options: .atomic)
    }

    private static func syntheticLightSnapshot() -> LightSnapshot {
        SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: syntheticFacts(), now: now),
            allFacts: syntheticFacts(),
            now: now,
            sourceHealth: syntheticSourceHealth
        )
    }

    private static let syntheticSourceHealth = [
        SourceHealth(sourceID: "synthetic-missing", isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE"),
    ]

    private static func syntheticFacts() -> [UsageFact] {
        let models = ["gpt-a", "gpt-b", "gpt-c", "other-model"]
        let displays = ["Model A", "Model B", "Model C", "Other"]
        let outputByModel = [410, 280, 150, 86]
        let closedEnd = floor(now.timeIntervalSince1970 / 5) * 5
        return (1...36).flatMap { bucket in
            models.indices.map { modelIndex in
            let wave = ((bucket * (modelIndex + 2)) % 5) * 12
            let observedAt = Date(timeIntervalSince1970: closedEnd - Double(bucket * 5 - 1))
            let index = (bucket - 1) * models.count + modelIndex
            return UsageFact(
                id: "snapshot-fact-\(index)",
                schemaVersion: "synthetic-snapshot-v1",
                sourceID: "synthetic-codex",
                codingAgent: .codex,
                model: ModelIdentity(raw: models[modelIndex], display: displays[modelIndex]),
                sessionID: "snapshot-session-\(index % 10)",
                turnID: "snapshot-turn-\(index)",
                observedAt: observedAt,
                outputTokens: outputByModel[modelIndex] + wave,
                measurementQuality: .measured,
                authority: "synthetic-snapshot",
                definitionVersion: OutputThroughputDefinition.version
            )
            }
        }
    }
}

@MainActor
private final class SnapshotLaunchAtLoginService: LaunchAtLoginService {
    func registrationStatus() -> LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class SnapshotUpdateService: UpdateCheckingService {
    func checkForUpdates() {}
}

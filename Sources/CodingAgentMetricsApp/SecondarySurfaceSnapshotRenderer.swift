import AppKit
import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import Foundation
import SwiftUI

enum SnapshotSurface: String, CaseIterable, Equatable {
    case settings
    case trends
    case dataDiagnostics = "data-diagnostics"
    case aboutUpdates = "about-updates"
}

enum SnapshotAppearance: String, CaseIterable, Equatable {
    case light
    case dark

    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    var nsAppearance: NSAppearance.Name {
        self == .light ? .aqua : .darkAqua
    }
}

@MainActor
enum SecondarySurfaceSnapshotRenderer {
    static let pointWidth = AppIdentity.popoverWidth
    static let maximumPointHeight: CGFloat = 720
    static let scale: CGFloat = 2
    static let now = Date(timeIntervalSince1970: 1_771_200)

    /// Rendering only ever reads an in-memory defaults domain. The suite name carries a
    /// per-process token so a stale on-disk domain can never change golden pixels, and this
    /// path must never fall back to `.standard` or write the user's preferences.
    static let defaultsSuite = "dev.codingagentmetrics.secondary-snapshot-renderer.\(UUID().uuidString)"

    @MainActor
    static func makeVolatileDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.register(defaults: [
            EnhancedTelemetryController.defaultsKey: false,
            DisplayPreferencesStore.windowKey: OutputThroughputWindow.threeMinutes.rawValue,
            DisplayPreferencesStore.cadenceKey: DisplayCadence.thirtySeconds.rawValue,
        ])
        return defaults
    }

    static func goldenResourceName(surface: SnapshotSurface, appearance: SnapshotAppearance) -> String {
        "secondary-\(surface.rawValue)-\(appearance.rawValue)-2x"
    }

    static func contactSheetGoldenResourceName(appearance: SnapshotAppearance) -> String {
        "secondary-surfaces-contact-sheet-\(appearance.rawValue)-2x"
    }

    static func renderBitmap(
        surface: SnapshotSurface,
        appearance: SnapshotAppearance,
        mutateOnePixel: Bool = false
    ) throws -> NSBitmapImageRep {
        try renderBitmap(
            surface: surface,
            appearance: appearance,
            mutateOnePixel: mutateOnePixel,
            warmsDarkTrendRenderer: true
        )
    }

    private static func renderBitmap(
        surface: SnapshotSurface,
        appearance: SnapshotAppearance,
        mutateOnePixel: Bool,
        warmsDarkTrendRenderer: Bool
    ) throws -> NSBitmapImageRep {
        // Swift Charts resolves part of its drawing state during its first composition.
        // Always prime a dark Trends snapshot with its fixed light fixture first so a
        // fresh snapshot CLI process and an in-process test render identical pixels.
        if warmsDarkTrendRenderer, surface == .trends, appearance == .dark {
            _ = try renderBitmap(
                surface: .trends,
                appearance: .light,
                mutateOnePixel: false,
                warmsDarkTrendRenderer: false
            )
        }
        _ = NSApplication.shared
        let originalAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance.nsAppearance)
        defer { NSApp.appearance = originalAppearance }

        let root = rootView(surface: surface, appearance: appearance)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: appearance.nsAppearance)
        hosting.frame = NSRect(x: 0, y: 0, width: pointWidth, height: maximumPointHeight)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance.nsAppearance)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        hosting.layoutSubtreeIfNeeded()
        let height = min(maximumPointHeight, max(240, hosting.fittingSize.height))
        hosting.frame.size = NSSize(width: pointWidth, height: height)
        window.setContentSize(hosting.frame.size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pointWidth * scale),
            pixelsHigh: Int((height * scale).rounded(.up)),
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
        NSAppearance(named: appearance.nsAppearance)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        if mutateOnePixel {
            SummaryPopoverPixelComparator.mutateOnePixel(bitmap)
        }
        return bitmap
    }

    static func writePNG(
        surface: SnapshotSurface,
        appearance: SnapshotAppearance,
        to url: URL,
        mutateOnePixel: Bool = false
    ) throws {
        let bitmap = try renderBitmap(surface: surface, appearance: appearance, mutateOnePixel: mutateOnePixel)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SummaryPopoverSnapshotRendererError.pngEncodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    static func renderContactSheet(appearance: SnapshotAppearance) throws -> NSBitmapImageRep {
        let top = try [SnapshotSurface.settings, .trends].map {
            try renderBitmap(surface: $0, appearance: appearance)
        }
        let bottom = try [SnapshotSurface.dataDiagnostics, .aboutUpdates].map {
            try renderBitmap(surface: $0, appearance: appearance)
        }
        let topHeight = top.map(\.pixelsHigh).max() ?? 0
        let bottomHeight = bottom.map(\.pixelsHigh).max() ?? 0
        let width = max(top.map(\.pixelsWide).reduce(0, +), bottom.map(\.pixelsWide).reduce(0, +))
        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: topHeight + bottomHeight,
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
        guard let destination = sheet.bitmapData else {
            throw SummaryPopoverSnapshotRendererError.renderSurfaceUnavailable
        }
        guard let background = top[0].bitmapData else {
            throw SummaryPopoverSnapshotRendererError.renderSurfaceUnavailable
        }
        for row in 0..<sheet.pixelsHigh {
            for column in 0..<sheet.pixelsWide {
                let offset = row * sheet.bytesPerRow + column * sheet.samplesPerPixel
                destination.advanced(by: offset).update(from: background, count: sheet.samplesPerPixel)
            }
        }
        let tiles = [
            (bitmap: top[0], x: 0, y: 0),
            (bitmap: top[1], x: top[0].pixelsWide, y: 0),
            (bitmap: bottom[0], x: 0, y: topHeight),
            (bitmap: bottom[1], x: bottom[0].pixelsWide, y: topHeight),
        ]
        for tile in tiles {
            guard let source = tile.bitmap.bitmapData,
                  tile.bitmap.samplesPerPixel == sheet.samplesPerPixel else {
                throw SummaryPopoverSnapshotRendererError.renderSurfaceUnavailable
            }
            let copiedBytesPerRow = tile.bitmap.pixelsWide * tile.bitmap.samplesPerPixel
            for row in 0..<tile.bitmap.pixelsHigh {
                let sourceOffset = row * tile.bitmap.bytesPerRow
                let destinationOffset = (tile.y + row) * sheet.bytesPerRow + tile.x * sheet.samplesPerPixel
                destination.advanced(by: destinationOffset).update(from: source.advanced(by: sourceOffset), count: copiedBytesPerRow)
            }
        }
        sheet.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(topHeight + bottomHeight) / scale)
        return sheet
    }

    static func writeContactSheetPNG(appearance: SnapshotAppearance, to url: URL) throws {
        let sheet = try renderContactSheet(appearance: appearance)
        guard let data = sheet.representation(using: .png, properties: [:]) else {
            throw SummaryPopoverSnapshotRendererError.pngEncodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func rootView(surface: SnapshotSurface, appearance: SnapshotAppearance) -> some View {
        let session = AccessibilitySession()
        session.openPanel()
        switch surface {
        case .settings:
            session.activate(.settings)
        case .trends:
            session.activate(.viewTrends)
        case .dataDiagnostics:
            session.activate(.settings)
            session.activate(.openDataDiagnostics)
        case .aboutUpdates:
            session.activate(.settings)
            session.activate(.openAboutUpdates)
        }

        let defaults = Self.makeVolatileDefaults()
        let preferences = DisplayPreferencesController(store: DisplayPreferencesStore(defaults: defaults))
        let services = AppLifecycleServices(
            launchAtLogin: LaunchAtLoginController(service: SecondarySnapshotLaunchAtLoginService()),
            updates: UpdateCheckController(service: SecondarySnapshotUpdateService())
        )
        let telemetry = EnhancedTelemetryController(runtime: nil, defaults: defaults)
        let facts = syntheticFacts()
        let light = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: facts, now: now),
            allFacts: facts,
            now: now
        )
        let snapshots = RuntimeSnapshots(
            light: light,
            detail: TrendBuilder().build(facts: facts, now: now)
        )
        let diagnostics = DiagnosticActionController(
            generate: { Data("{\"fixture\":\"secondary-surface-snapshot-v1\"}".utf8) },
            copy: { _ in },
            userSelectedSave: { _ in false }
        )

        return (
            Group {
            if surface == .aboutUpdates {
                SnapshotSecondarySurfaceContainer(title: "About & Updates", accessibility: session) {
                    AboutUpdatesSurfaceView(
                        presentation: AppAboutPresentation(info: snapshotAboutInfo),
                        updates: services.updates,
                        accessibility: session
                    )
                }
            } else {
                SummaryPopoverView(
                    snapshot: light,
                    snapshots: snapshots,
                    accessibility: session,
                    lifecycleServices: services,
                    telemetry: telemetry,
                    resetData: ResetDataController(),
                    diagnostics: diagnostics,
                    preferences: preferences,
                    clock: SecondarySnapshotFixedClock(now: now)
                )
            }
            }
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.colorScheme, appearance.colorScheme)
            .transaction { $0.animation = nil }
        )
    }

    private static let snapshotAboutInfo: [String: Any] = [
        "CFBundleName": "Agent Metrics",
        "CFBundleShortVersionString": "0.2.2",
        "CFBundleVersion": "7",
        "LSMinimumSystemVersion": "14.0",
        "SUFeedURL": "https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml",
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
                    id: "secondary-snapshot-fact-\(index)",
                    schemaVersion: "synthetic-secondary-snapshot-v1",
                    sourceID: "synthetic-codex",
                    codingAgent: .codex,
                    model: ModelIdentity(raw: models[modelIndex], display: displays[modelIndex]),
                    sessionID: "secondary-snapshot-session-\(index % 10)",
                    turnID: "secondary-snapshot-turn-\(index)",
                    observedAt: observedAt,
                    outputTokens: outputByModel[modelIndex] + wave,
                    measurementQuality: .measured,
                    authority: "synthetic-secondary-snapshot",
                    definitionVersion: OutputThroughputDefinition.version,
                    tokenParts: TokenParts(
                        inputUncached: 200 + wave,
                        cacheRead: 40,
                        cacheWrite: 10,
                        outputVisible: outputByModel[modelIndex] + wave,
                        reasoning: 20
                    ),
                    modelCallID: "secondary-snapshot-call-\(index)",
                    modelCallCapability: .available
                )
            }
        }
    }
}

@MainActor
private final class SecondarySnapshotLaunchAtLoginService: LaunchAtLoginService {
    func registrationStatus() -> LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class SecondarySnapshotUpdateService: UpdateCheckingService {
    func checkForUpdates() {}
}

private struct SecondarySnapshotFixedClock: Clock {
    let now: Date
}

private struct SnapshotSecondarySurfaceContainer<Content: View>: View {
    let title: String
    @ObservedObject var accessibility: AccessibilitySession
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back") { accessibility.escape() }
                Spacer()
                Text(title).font(.headline)
            }
            ScrollView {
                content()
            }
            .frame(maxHeight: SecondarySurfaceSnapshotRenderer.maximumPointHeight)
        }
        .padding(14)
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
        .frame(maxHeight: SecondarySurfaceSnapshotRenderer.maximumPointHeight)
        .background(.regularMaterial)
    }
}

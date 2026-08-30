import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

/// Contract for Summary ↔ Detail ↔ Settings panel sizing.
/// Mirrors production: one hosting root, KeyablePanel contentMinSize, hosting
/// sizingOptions, and resizePanel after surface changes.
@Suite(.serialized)
struct PopoverSizeContractTests {
    private static let widthTolerance: CGFloat = 1

    @Test @MainActor
    func summaryDetailReturnRestoresIdealWidthWithoutCumulativeNarrowing() async {
        let harness = PopoverSizeHarness(detailContent: .populated)
        defer { harness.close() }
        await harness.start()

        let summary = await harness.measure("summary")
        await harness.activateDetail()
        let detail = await harness.measure("detail")
        await harness.returnToSummary()
        let returned = await harness.measure("returned")

        var afterRepeats: [MeasuredSizes] = []
        for index in 1...3 {
            await harness.activateDetail()
            _ = await harness.measure("detail-repeat-\(index)")
            await harness.returnToSummary()
            afterRepeats.append(await harness.measure("returned-repeat-\(index)"))
        }

        await harness.dismissAndReopen()
        let reopened = await harness.measure("reopened")

        report(summary, detail, returned, reopened, repeats: afterRepeats)
        for sample in [summary, detail, returned, reopened] + afterRepeats {
            assertUserVisibleWidth(sample, expected: AppIdentity.popoverWidth)
        }
    }

    @Test @MainActor
    func emptyDetailDoesNotPermanentlyPolluteSummaryWidth() async {
        let harness = PopoverSizeHarness(detailContent: .empty)
        defer { harness.close() }
        await harness.start()

        let summary = await harness.measure("empty-summary")
        await harness.activateDetail()
        let detail = await harness.measure("empty-detail")
        await harness.returnToSummary()
        let returned = await harness.measure("empty-returned")

        report(summary, detail, returned, repeats: [])
        assertUserVisibleWidth(summary, expected: AppIdentity.popoverWidth)
        assertUserVisibleWidth(detail, expected: AppIdentity.popoverWidth)
        assertUserVisibleWidth(returned, expected: AppIdentity.popoverWidth)
        assertHeightRecovers(from: summary, through: detail, returning: returned)
    }

    @Test @MainActor
    func settingsAndDetailShareHostingRootWithoutShrinkingSummary() async {
        let harness = PopoverSizeHarness(detailContent: .populated)
        defer { harness.close() }
        await harness.start()

        await harness.activateSettings()
        let settings = await harness.measure("settings")
        await harness.returnToSummary()
        let afterSettings = await harness.measure("after-settings")
        await harness.activateDetail()
        let detail = await harness.measure("after-settings-detail")
        await harness.returnToSummary()
        let afterDetail = await harness.measure("after-settings-detail-return")

        report(settings, afterSettings, detail, afterDetail, repeats: [])
        for sample in [settings, afterSettings, detail, afterDetail] {
            assertUserVisibleWidth(sample, expected: AppIdentity.popoverWidth)
        }
    }

    @Test @MainActor
    func secondarySurfacesKeepWidthAndStayWithinVisibleHeightAcrossRoundTrips() async {
        let harness = PopoverSizeHarness(detailContent: .populated)
        defer { harness.close() }
        await harness.start()

        let summary = await harness.measure("summary")
        await harness.activateDetail()
        let trends = await harness.measure("trends")
        await harness.returnToSummary()
        await harness.activateSettings()
        let settings = await harness.measure("settings")
        await harness.activateDataDiagnostics()
        let data = await harness.measure("data")
        await harness.returnToSettings()
        await harness.activateAboutUpdates()
        let about = await harness.measure("about")
        await harness.returnToSettings()
        await harness.returnToSummary()
        let returned = await harness.measure("returned")
        await harness.dismissAndReopen()
        let reopened = await harness.measure("reopened")

        report(summary, trends, settings, data, about, returned, reopened, repeats: [])
        for sample in [summary, trends, settings, data, about, returned, reopened] {
            assertUserVisibleWidth(sample, expected: AppIdentity.popoverWidth)
            assertHeightWithinVisibleFrame(sample, visibleHeight: harness.visibleHeight)
        }
    }

    private func assertUserVisibleWidth(_ sample: MeasuredSizes, expected: Double) {
        #expect(
            abs(sample.panelWidth - expected) < Self.widthTolerance,
            "\(sample.label) panelWidth=\(sample.panelWidth) bounds=\(sample.boundsWidth) fitting=\(sample.fittingWidth) min=\(sample.minWidth) ideal=\(sample.idealWidth) max=\(sample.maxWidth) placeFit=\(sample.placementFromFittingWidth)"
        )
        #expect(
            abs(sample.boundsWidth - expected) < Self.widthTolerance,
            "\(sample.label) boundsWidth=\(sample.boundsWidth) panel=\(sample.panelWidth)"
        )
        #expect(
            abs(sample.idealWidth - expected) < Self.widthTolerance,
            "\(sample.label) idealWidth=\(sample.idealWidth) min=\(sample.minWidth) max=\(sample.maxWidth) fitting=\(sample.fittingWidth)"
        )
        #expect(
            abs(sample.contentMinWidth - expected) < Self.widthTolerance,
            "\(sample.label) contentMinWidth=\(sample.contentMinWidth) is not the 440pt window contract"
        )
        #expect(
            sample.panelHeight + Self.widthTolerance >= PanelPlacement.minimumContentHeight,
            "\(sample.label) panelHeight=\(sample.panelHeight) collapsed below minimum content height"
        )
    }

    private func assertHeightWithinVisibleFrame(_ sample: MeasuredSizes, visibleHeight: CGFloat) {
        #expect(
            sample.panelHeight <= visibleHeight + Self.widthTolerance,
            "\(sample.label) panelHeight=\(sample.panelHeight) exceeds visible height \(visibleHeight)"
        )
    }

    private func assertHeightRecovers(from summary: MeasuredSizes, through detail: MeasuredSizes, returning returned: MeasuredSizes) {
        #expect(
            returned.panelHeight + 8 >= summary.panelHeight,
            "returning from Detail pinned height at \(returned.panelHeight); summary was \(summary.panelHeight), detail was \(detail.panelHeight)"
        )
        #expect(
            returned.panelHeight > 90,
            "returned panelHeight=\(returned.panelHeight) stayed on the empty-detail 84pt pin"
        )
    }

    private func report(_ samples: MeasuredSizes..., repeats: [MeasuredSizes]) {
        let lines = (samples + repeats).map(\.description).joined(separator: "\n")
        print("[PopoverSizeContract]\n\(lines)")
    }
}

@MainActor
private final class PopoverSizeHarness {
    enum DetailContent {
        case empty
        case populated
    }

    private let panel: KeyablePanel
    private let hosting: NSHostingView<SummaryPopoverView>
    private let accessibility: AccessibilitySession
    private let snapshots: RuntimeSnapshots
    private let visibleFrame: NSRect
    var visibleHeight: CGFloat { visibleFrame.height }

    init(detailContent: DetailContent) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let now = Date(timeIntervalSince1970: 1_771_200)
        let facts = detailContent == .populated ? Self.syntheticFacts(now: now) : []
        let light: LightSnapshot? = detailContent == .populated
            ? SnapshotBuilder().buildLightSnapshot(
                sample: LiveSampler().sample(facts: facts, now: now),
                allFacts: facts,
                now: now
            )
            : nil
        let detail: TrendSnapshot? = detailContent == .populated
            ? TrendBuilder().build(facts: facts, now: now)
            : nil

        accessibility = AccessibilitySession()
        accessibility.openPanel()
        snapshots = RuntimeSnapshots(light: light, detail: detail)

        let suite = "dev.codingagentmetrics.popover-size-contract.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = DisplayPreferencesController(store: DisplayPreferencesStore(defaults: defaults))
        let telemetry = EnhancedTelemetryController(runtime: nil, defaults: defaults)

        panel = KeyablePanel(
            contentRect: NSRect(x: 80, y: 80, width: AppIdentity.popoverWidth, height: 292),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = SummaryPopoverView(
            snapshot: light,
            snapshots: snapshots,
            accessibility: accessibility,
            lifecycleServices: inertLifecycleServices(),
            telemetry: telemetry,
            preferences: preferences,
            clock: FixedClock(now: now)
        )
        hosting = NSHostingView(rootView: root)
        panel.installMetricsHostingView(hosting)
        visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        panel.makeKeyAndOrderFront(nil)
        resizeLikeProduction()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    func start() async {
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func activateDetail() async {
        accessibility.activate(.viewTrends)
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func activateSettings() async {
        accessibility.activate(.settings)
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func activateDataDiagnostics() async {
        if accessibility.surface != .settings {
            accessibility.activate(.settings)
            await pump()
        }
        accessibility.activate(.openDataDiagnostics)
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func activateAboutUpdates() async {
        if accessibility.surface != .settings {
            accessibility.activate(.settings)
            await pump()
        }
        accessibility.activate(.openAboutUpdates)
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func returnToSettings() async {
        accessibility.escape()
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func returnToSummary() async {
        accessibility.escape()
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func dismissAndReopen() async {
        accessibility.dismissToStatusItem()
        panel.orderOut(nil)
        await pump()
        accessibility.openPanel()
        panel.makeKeyAndOrderFront(nil)
        await pump()
        resizeLikeProduction()
        await pump()
    }

    func measure(_ label: String) async -> MeasuredSizes {
        hosting.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        let boundsWidth = hosting.bounds.width
        let fitting = hosting.fittingSize
        let intrinsic = hosting.intrinsicContentSize
        let minWidth = fittingWidth(for: .minSize)
        let idealWidth = fittingWidth(for: .intrinsicContentSize)
        let maxWidth = fittingWidth(for: .maxSize)
        resizeLikeProduction()
        let placementFromPopover = PanelPlacement.resizedFrame(
            from: panel.frame,
            contentSize: PanelPlacement.metricsContentSize(fittingHeight: fitting.height),
            visibleFrame: visibleFrame
        )
        let placementFromFitting = PanelPlacement.resizedFrame(
            from: panel.frame,
            contentSize: NSSize(width: fitting.width, height: max(fitting.height, PanelPlacement.minimumContentHeight)),
            visibleFrame: visibleFrame
        )
        return MeasuredSizes(
            label: label,
            surface: String(describing: accessibility.surface),
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            boundsWidth: boundsWidth,
            fittingWidth: fitting.width,
            fittingHeight: fitting.height,
            intrinsicWidth: intrinsic.width,
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            contentMinWidth: max(panel.contentMinSize.width, panel.minSize.width),
            placementFromPopoverWidth: placementFromPopover.width,
            placementFromFittingWidth: placementFromFitting.width,
            sizingOptions: String(describing: hosting.sizingOptions)
        )
    }

    private func fittingWidth(for options: NSHostingSizingOptions) -> CGFloat {
        hosting.sizingOptions = options
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let width = hosting.fittingSize.width
        hosting.sizingOptions = KeyablePanel.metricsHostingSizingOptions
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        panel.applyMetricsPopoverContract()
        return width
    }

    private func resizeLikeProduction() {
        hosting.layoutSubtreeIfNeeded()
        panel.applyMetricsPopoverContract()
        let fitting = hosting.fittingSize
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        panel.setFrame(
            PanelPlacement.resizedFrame(
                from: panel.frame,
                contentSize: PanelPlacement.metricsContentSize(fittingHeight: fitting.height),
                visibleFrame: visible
            ),
            display: true
        )
        panel.applyMetricsPopoverContract()
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
    }

    private func pump() async {
        hosting.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        hosting.displayIfNeeded()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 40_000_000)
        hosting.layoutSubtreeIfNeeded()
    }

    private static func syntheticFacts(now: Date) -> [UsageFact] {
        (0..<12).map { index in
            let observedAt = now.addingTimeInterval(-Double(index + 1) * 5)
            return UsageFact(
                id: "popover-size-fact-\(index)",
                schemaVersion: "popover-size-v1",
                sourceID: "synthetic-codex",
                codingAgent: .codex,
                model: ModelIdentity(raw: "synthetic-model-\(index % 3)", display: "Synthetic Model \(index % 3)"),
                sessionID: "synthetic-session-\(index % 2)",
                turnID: "synthetic-turn-\(index)",
                observedAt: observedAt,
                outputTokens: 100 + index,
                measurementQuality: .measured,
                authority: "synthetic-popover-size",
                definitionVersion: "synthetic-popover-size-v1",
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
    }
}

private struct MeasuredSizes: CustomStringConvertible {
    var label: String
    var surface: String
    var panelWidth: CGFloat
    var panelHeight: CGFloat
    var boundsWidth: CGFloat
    var fittingWidth: CGFloat
    var fittingHeight: CGFloat
    var intrinsicWidth: CGFloat
    var minWidth: CGFloat
    var idealWidth: CGFloat
    var maxWidth: CGFloat
    var contentMinWidth: CGFloat
    var placementFromPopoverWidth: CGFloat
    var placementFromFittingWidth: CGFloat
    var sizingOptions: String

    var description: String {
        "\(label) surface=\(surface) panel=\(fmt(panelWidth))x\(fmt(panelHeight)) boundsW=\(fmt(boundsWidth)) fitting=\(fmt(fittingWidth))x\(fmt(fittingHeight)) intrinsicW=\(fmt(intrinsicWidth)) min=\(fmt(minWidth)) ideal=\(fmt(idealWidth)) max=\(fmt(maxWidth)) contentMin=\(fmt(contentMinWidth)) place440=\(fmt(placementFromPopoverWidth)) placeFit=\(fmt(placementFromFittingWidth)) sizing=\(sizingOptions)"
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

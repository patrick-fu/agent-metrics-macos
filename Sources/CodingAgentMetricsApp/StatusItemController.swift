import AppKit
import Combine
import CodingAgentMetricsCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private enum LightLoad: Sendable, Equatable {
        case ingest(MetricFilter, PerformanceRange, Int)
        case stored(MetricFilter, PerformanceRange, Int)
    }

    private struct DetailLoad: Sendable, Equatable {
        var filter: MetricFilter
        var windowSeconds: Int
    }

    private let statusItem: NSStatusItem
    private let panel: KeyablePanel
    private let runtime: TelemetryRuntime?
    private let telemetry: EnhancedTelemetryController
    private let snapshots: RuntimeSnapshots
    private let lightGate = DetailQueryGate()
    private let detailGate = DetailQueryGate()
    private let lightQueue = DispatchQueue(label: "dev.codingagentmetrics.light-snapshot", qos: .utility)
    private let detailQueue = DispatchQueue(label: "dev.codingagentmetrics.detail-snapshot", qos: .userInitiated)
    private var lightLoader: LatestBackgroundLoader<LightLoad, LightSnapshot>!
    private var detailLoader: LatestBackgroundLoader<DetailLoad, TrendSnapshot>!
    private var filter = MetricFilter.all
    private var performanceRange = PerformanceRange.oneHour
    private var detailFilter: MetricFilter?
    private let displayPreferences = DisplayPreferencesController()
    private var scheduler = SnapshotScheduler()
    private var latestLight: LightSnapshot?
    private var heroPublication = LightSnapshotPublishDecision()
    private var refreshTimer: Timer?
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var keyRouting = AccessibilityKeyRouting()
    private let accessibility = AccessibilitySession()
    private var accessibilityObserver: AnyCancellable?
    private var panelLifecycle: AccessibilityPanelLifecycle!
    private var isDismissingPanel = false
    private var lastResizedSurface: AccessibilityNavigation.Surface?
    private lazy var resetData: ResetDataController = {
        guard let runtime else { return ResetDataController() }
        return ResetDataController(reset: { [weak self, runtime] in
            self?.lightLoader.invalidate()
            self?.detailLoader.invalidate()
            let result = try runtime.resetData()
            self?.snapshots.light = nil
            self?.snapshots.detail = nil
            self?.detailFilter = nil
            return result
        })
    }()
    private lazy var diagnostics = DiagnosticActionController(
        generate: { [weak self] in
            guard let snapshot = self?.snapshots.light else {
                throw DiagnosticActionError.snapshotUnavailable
            }
            let info = Bundle.main.infoDictionary ?? [:]
            let input = DiagnosticExportInput(
                snapshot: snapshot,
                appVersion: info["CFBundleShortVersionString"] as? String ?? "unavailable",
                buildVersion: info["CFBundleVersion"] as? String ?? "unavailable",
                parserVersions: [
                    CodexRolloutParser.semanticVersion,
                    ClaudeTranscriptParser.semanticVersion,
                ],
                schemaVersions: [
                    CodexRolloutParser.schemaVersion,
                    ClaudeTranscriptParser.schemaVersion,
                ]
            )
            return try DiagnosticExporter().preview(input)
        },
        copy: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw DiagnosticActionError.pasteboardWriteFailed
            }
        },
        userSelectedSave: { data in
            let panel = NSSavePanel()
            panel.title = "Save Agent Metrics Diagnostics"
            panel.nameFieldStringValue = "agent-metrics-diagnostics.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            try data.write(to: url, options: .atomic)
            return true
        }
    )

    override init() {
        let createdRuntime = try? TelemetryRuntime(
            storeURL: Self.storeURL(),
            sourceAdapters: [
                CodexRolloutSourceAdapter(),
                ClaudeTranscriptSourceAdapter(),
            ]
        )
        runtime = createdRuntime
        telemetry = EnhancedTelemetryController(runtime: createdRuntime)
        snapshots = RuntimeSnapshots()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: AppIdentity.popoverWidth, height: 292),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        lightLoader = LatestBackgroundLoader(queue: lightQueue, gate: lightGate) { request in
            switch request {
            case let .ingest(filter, range, windowSeconds):
                try? createdRuntime?.lightSnapshot(filter: filter, performanceRange: range, windowSeconds: windowSeconds)
            case let .stored(filter, range, windowSeconds):
                try? createdRuntime?.lightSnapshotFromStore(filter: filter, performanceRange: range, windowSeconds: windowSeconds)
            }
        }
        detailLoader = LatestBackgroundLoader(queue: detailQueue, gate: detailGate) { request in
            try? createdRuntime?.trendSnapshot(filter: request.filter, windowSeconds: request.windowSeconds)
        }
        scheduler.setDisplayCadence(displayPreferences.cadence)
        configureStatusItem()
        configurePanel()
        refreshSnapshots()
        configureContent()
        startRefreshTimer()
        observeAccessibility()
        observeMenuTracking()
        panelLifecycle = AccessibilityPanelLifecycle(
            panel: panel,
            accessibility: accessibility,
            hasModalWindow: { NSApp.modalWindow != nil },
            isMenuTracking: { [weak self] in self?.keyRouting.isMenuTracking ?? false },
            onDismiss: { [weak self] in self?.dismissPanel() }
        )
        diagnostics.onExternalModalFinished = { [weak self] in
            self?.panelLifecycle.onExternalModalFinished()
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            dismissPanel()
        } else {
            showPanel()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        panelLifecycle.handleResignKey()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Agent Metrics"
        )
        button.imagePosition = .imageLeading
        button.title = "—"
        button.target = self
        button.action = #selector(togglePanel)
        button.setAccessibilityLabel("Agent Metrics")
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier("status-item")
    }

    private func configurePanel() {
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
        panel.delegate = self
    }

    private func configureContent() {
        let root = SummaryPopoverView(snapshot: snapshots.light, snapshots: snapshots, accessibility: accessibility, telemetry: telemetry, resetData: resetData, diagnostics: diagnostics, loadSnapshot: { [weak self] newFilter, performanceRange in
            self?.requestStoredLightSnapshot(filter: newFilter, performanceRange: performanceRange, publishHero: true)
        }, loadTrends: { [weak self] newFilter in
            self?.requestDetailSnapshot(filter: newFilter)
        }, preferences: displayPreferences, onWindowChange: { [weak self] window in
            self?.applyWindow(window)
        }, onCadenceChange: { [weak self] cadence in
            self?.applyCadence(cadence)
        })
        panel.installMetricsHostingView(NSHostingView(rootView: root))
        resizePanel()
    }

    private func resizePanel() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.applyMetricsPopoverContract()
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        panel.setFrame(
            PanelPlacement.resizedFrame(
                from: panel.frame,
                contentSize: PanelPlacement.metricsContentSize(fittingHeight: panel.metricsFittingSize.height),
                visibleFrame: visibleFrame
            ),
            display: true
        )
        panel.applyMetricsPopoverContract()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: SnapshotScheduler.detailInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshots() }
        }
    }

    private func refreshSnapshots() {
        let schedule = scheduler.tick(at: Date())
        if schedule.publishLight { requestLightSnapshot(publishHero: schedule.publishDisplay) }
        else if schedule.publishDisplay { publishDisplayedHero() }
        if schedule.publishDetail { requestDetailSnapshot() }
    }

    private func requestLightSnapshot(publishHero: Bool) {
        let requestedFilter = filter
        let requestedRange = performanceRange
        let requestedWindow = displayPreferences.window.seconds
        heroPublication.noteRequested(publishHero: publishHero)
        lightLoader.submit(.ingest(requestedFilter, requestedRange, requestedWindow)) { [weak self] light in
            self?.finishLightLoad(light, expectedFilter: requestedFilter, expectedRange: requestedRange, publishHero: publishHero)
        }
    }

    private func requestStoredLightSnapshot(filter newFilter: MetricFilter, performanceRange: PerformanceRange, publishHero: Bool) {
        filter = newFilter
        self.performanceRange = performanceRange
        detailFilter = nil
        snapshots.detail = nil
        detailLoader.invalidate()
        let requestedWindow = displayPreferences.window.seconds
        heroPublication.noteRequested(publishHero: publishHero)
        lightLoader.submit(.stored(newFilter, performanceRange, requestedWindow)) { [weak self] light in
            self?.finishLightLoad(light, expectedFilter: newFilter, expectedRange: performanceRange, publishHero: publishHero)
        }
    }

    private func finishLightLoad(
        _ light: LightSnapshot?,
        expectedFilter: MetricFilter,
        expectedRange: PerformanceRange,
        publishHero: Bool
    ) {
        guard filter == expectedFilter, performanceRange == expectedRange else { return }
        let update = heroPublication.complete(output: light, publishHero: publishHero, latest: latestLight)
        latestLight = update.latest
        if let hero = update.hero {
            publish(hero)
        }
        resizePanelSoon()
    }

    private func publishDisplayedHero() {
        publish(latestLight)
    }

    private func publish(_ light: LightSnapshot?) {
        snapshots.light = light
        updateStatusItem(light)
    }

    private func applyWindow(_ window: OutputThroughputWindow) {
        displayPreferences.window = window
        requestStoredLightSnapshot(filter: filter, performanceRange: performanceRange, publishHero: true)
        if panel.isVisible {
            detailFilter = nil
            requestDetailSnapshot(filter: filter)
        }
    }

    private func applyCadence(_ cadence: DisplayCadence) {
        displayPreferences.cadence = cadence
        scheduler.setDisplayCadence(cadence)
        publishDisplayedHero()
    }

    private func updateStatusItem(_ snapshot: LightSnapshot?) {
        guard let button = statusItem.button else { return }
        let presentation = snapshot.map { LightSnapshotPresentation(snapshot: $0) }
        button.title = presentation?.menuBarTitleText ?? "—"
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(presentation?.menuBarAccessibilityLabel ?? "Agent Metrics")
    }

    private func requestDetailSnapshot(filter requestedFilter: MetricFilter? = nil) {
        guard panel.isVisible else { return }
        let isUserRequest = requestedFilter != nil
        let requestedFilter = requestedFilter ?? filter
        guard requestedFilter == filter else { return }
        if isUserRequest, detailFilter == requestedFilter, snapshots.detail != nil { return }
        detailLoader.submit(DetailLoad(filter: requestedFilter, windowSeconds: displayPreferences.window.seconds)) { [weak self] detail in
            guard let self, self.panel.isVisible, self.filter == requestedFilter else { return }
            if let detail {
                self.detailFilter = requestedFilter
                self.snapshots.detail = detail
            }
            self.resizePanelSoon()
        }
    }

    private func resizePanelSoon() {
        DispatchQueue.main.async { [weak self] in self?.resizePanel() }
    }

    private func showPanel() {
        scheduler.setPopoverVisible(true)
        accessibility.openPanel()
        requestStoredLightSnapshot(filter: filter, performanceRange: performanceRange, publishHero: true)
        refreshSnapshots()
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let panelSize = panel.frame.size
        let x = buttonRect.midX - panelSize.width / 2
        let y = buttonRect.minY - panelSize.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.metricsHostingView ?? panel.contentView)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panelLifecycle.handleExternalDismissRequest()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
    }

    private func dismissPanel() {
        guard !isDismissingPanel else { return }
        guard panel.isVisible || accessibility.isPanelVisible else { return }
        isDismissingPanel = true
        defer { isDismissingPanel = false }
        scheduler.setPopoverVisible(false)
        detailLoader.invalidate()
        if accessibility.isPanelVisible {
            accessibility.dismissToStatusItem()
        }
        panel.orderOut(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        restoreStatusItemFocus()
    }

    private func observeAccessibility() {
        accessibilityObserver = accessibility.$navigation.sink { [weak self] navigation in
            guard let self else { return }
            if navigation.surface == .dismissed {
                self.lastResizedSurface = nil
                if self.panel.isVisible {
                    self.dismissPanel()
                }
                return
            }
            if self.panel.isVisible, self.lastResizedSurface != navigation.surface {
                self.lastResizedSurface = navigation.surface
                self.resizePanelSoon()
            }
        }
    }

    private func observeMenuTracking() {
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyRouting.menuDidBeginTracking()
            }
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyRouting.menuDidEndTracking()
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let routed = AccessibilityKeyEvent(
            event: event,
            panel: panel,
            hasModalWindow: NSApp.modalWindow != nil
        )
        switch keyRouting.decision(for: routed) {
        case .handleEscape:
            handleEscapeFromPanel()
            return nil
        case .handleTab(let shift):
            accessibility.moveFocus(forward: !shift)
            return nil
        case .ignore:
            return event
        }
    }

    private func handleEscapeFromPanel() {
        switch accessibility.surface {
        case .diagnosticsConfirmation(let action):
            diagnostics.cancel(confirmation(for: action))
        case .resetConfirmation:
            resetData.cancelReset()
        default:
            break
        }
        accessibility.escape()
    }

    private func confirmation(for action: AccessibilityNavigation.DiagnosticsAction) -> DiagnosticActionController.Confirmation {
        switch action {
        case .copy: .copy
        case .save: .save
        case .preparePublicIssue: .preparePublicIssue
        }
    }

    private func restoreStatusItemFocus() {
        guard let button = statusItem.button else { return }
        button.window?.makeKeyAndOrderFront(nil)
        button.window?.makeFirstResponder(button)
    }

    private static func storeURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("facts.sqlite")
    }
}

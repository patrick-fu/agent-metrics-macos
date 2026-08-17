import AppKit
import CodingAgentMetricsCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private enum LightLoad: Sendable, Equatable {
        case ingest(MetricFilter, PerformanceRange)
        case stored(MetricFilter, PerformanceRange)
    }

    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private let runtime: TelemetryRuntime?
    private let telemetry: EnhancedTelemetryController
    private let snapshots: RuntimeSnapshots
    private let lightGate = DetailQueryGate()
    private let detailGate = DetailQueryGate()
    private let lightQueue = DispatchQueue(label: "dev.codingagentmetrics.light-snapshot", qos: .utility)
    private let detailQueue = DispatchQueue(label: "dev.codingagentmetrics.detail-snapshot", qos: .userInitiated)
    private var lightLoader: LatestBackgroundLoader<LightLoad, LightSnapshot>!
    private var detailLoader: LatestBackgroundLoader<MetricFilter, TrendSnapshot>!
    private var filter = MetricFilter.all
    private var performanceRange = PerformanceRange.oneHour
    private var detailFilter: MetricFilter?
    private var scheduler = SnapshotScheduler()
    private var refreshTimer: Timer?
    private var eventMonitor: Any?
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
            panel.title = "Save Privacy-Safe Diagnostics"
            panel.nameFieldStringValue = "coding-agent-metrics-diagnostics.json"
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
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppIdentity.popoverWidth, height: 292),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        lightLoader = LatestBackgroundLoader(queue: lightQueue, gate: lightGate) { request in
            switch request {
            case let .ingest(filter, range):
                try? createdRuntime?.lightSnapshot(filter: filter, performanceRange: range)
            case let .stored(filter, range):
                try? createdRuntime?.lightSnapshotFromStore(filter: filter, performanceRange: range)
            }
        }
        detailLoader = LatestBackgroundLoader(queue: detailQueue, gate: detailGate) { filter in
            try? createdRuntime?.trendSnapshot(filter: filter)
        }
        configureStatusItem()
        configurePanel()
        refreshSnapshots()
        configureContent()
        startRefreshTimer()
    }

    @objc func togglePanel() {
        if panel.isVisible {
            dismissPanel()
        } else {
            showPanel()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissPanel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Coding Agent Metrics"
        )
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel)
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
        let root = SummaryPopoverView(snapshot: snapshots.light, snapshots: snapshots, telemetry: telemetry, resetData: resetData, diagnostics: diagnostics, loadSnapshot: { [weak self] newFilter, performanceRange in
            self?.requestStoredLightSnapshot(filter: newFilter, performanceRange: performanceRange)
        }, loadTrends: { [weak self] newFilter in
            self?.requestDetailSnapshot(filter: newFilter)
        })
        .frame(width: AppIdentity.popoverWidth)
        panel.contentView = NSHostingView(rootView: root)
        resizePanel()
    }

    private func resizePanel() {
        if let content = panel.contentView {
            let fitting = content.fittingSize
            var frame = panel.frame
            frame.size = NSSize(width: AppIdentity.popoverWidth, height: max(fitting.height, 240))
            panel.setFrame(frame, display: true)
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: SnapshotScheduler.detailInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshots() }
        }
    }

    private func refreshSnapshots() {
        let schedule = scheduler.tick(at: Date())
        if schedule.publishLight { requestLightSnapshot() }
        if schedule.publishDetail { requestDetailSnapshot() }
    }

    private func requestLightSnapshot() {
        let requestedFilter = filter
        let requestedRange = performanceRange
        lightLoader.submit(.ingest(requestedFilter, requestedRange)) { [weak self] light in
            guard let self, self.filter == requestedFilter, self.performanceRange == requestedRange else { return }
            self.snapshots.light = light
            self.resizePanelSoon()
        }
    }

    private func requestStoredLightSnapshot(filter newFilter: MetricFilter, performanceRange: PerformanceRange) {
        filter = newFilter
        self.performanceRange = performanceRange
        detailFilter = nil
        snapshots.detail = nil
        detailLoader.invalidate()
        lightLoader.submit(.stored(newFilter, performanceRange)) { [weak self] light in
            guard let self, self.filter == newFilter, self.performanceRange == performanceRange else { return }
            self.snapshots.light = light
            self.resizePanelSoon()
        }
    }

    private func requestDetailSnapshot(filter requestedFilter: MetricFilter? = nil) {
        guard panel.isVisible else { return }
        let isUserRequest = requestedFilter != nil
        let requestedFilter = requestedFilter ?? filter
        guard requestedFilter == filter else { return }
        if isUserRequest, detailFilter == requestedFilter, snapshots.detail != nil { return }
        detailLoader.submit(requestedFilter) { [weak self] detail in
            guard let self, self.panel.isVisible, self.filter == requestedFilter else { return }
            self.detailFilter = requestedFilter
            self.snapshots.detail = detail
            self.resizePanelSoon()
        }
    }

    private func resizePanelSoon() {
        DispatchQueue.main.async { [weak self] in self?.resizePanel() }
    }

    private func showPanel() {
        scheduler.setPopoverVisible(true)
        refreshSnapshots()
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let panelSize = panel.frame.size
        let x = buttonRect.midX - panelSize.width / 2
        let y = buttonRect.minY - panelSize.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel()
        }
    }

    private func dismissPanel() {
        scheduler.setPopoverVisible(false)
        detailLoader.invalidate()
        panel.orderOut(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private static func storeURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("facts.sqlite")
    }
}

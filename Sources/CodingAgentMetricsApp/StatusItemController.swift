import AppKit
import CodingAgentMetricsCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private let runtime: TelemetryRuntime?
    private var eventMonitor: Any?

    override init() {
        runtime = try? TelemetryRuntime(
            storeURL: Self.storeURL(),
            sourceAdapters: [
                CodexRolloutSourceAdapter(),
                ClaudeTranscriptSourceAdapter(),
            ]
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppIdentity.popoverWidth, height: 292),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureStatusItem()
        configurePanel()
        renderSnapshot()
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

    private func renderSnapshot() {
        let snapshot = try? runtime?.lightSnapshot()
        let root = SummaryPopoverView(snapshot: snapshot)
            .frame(width: AppIdentity.popoverWidth)
        panel.contentView = NSHostingView(rootView: root)
        if let content = panel.contentView {
            let fitting = content.fittingSize
            var frame = panel.frame
            frame.size = NSSize(width: AppIdentity.popoverWidth, height: max(fitting.height, 240))
            panel.setFrame(frame, display: true)
        }
    }

    private func showPanel() {
        renderSnapshot()
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

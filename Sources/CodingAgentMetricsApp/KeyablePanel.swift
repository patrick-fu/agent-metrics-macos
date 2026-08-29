import AppKit
import CodingAgentMetricsCore
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static var metricsHostingSizingOptions: NSHostingSizingOptions {
        [.intrinsicContentSize]
    }

    private(set) weak var metricsHostingView: NSView?

    var metricsFittingSize: NSSize {
        let view = metricsHostingView ?? contentView
        view?.layoutSubtreeIfNeeded()
        return view?.fittingSize ?? .zero
    }

    func applyMetricsPopoverContract() {
        let minimum = NSSize(width: AppIdentity.popoverWidth, height: PanelPlacement.minimumContentHeight)
        let maximum = NSSize(width: AppIdentity.popoverWidth, height: 10_000)
        contentMinSize = minimum
        minSize = minimum
        contentMaxSize = maximum
        maxSize = maximum
    }

    func installMetricsHostingView<Content: View>(_ hosting: NSHostingView<Content>) {
        hosting.sizingOptions = Self.metricsHostingSizingOptions
        hosting.setContentHuggingPriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentHuggingPriority(.defaultLow, for: .vertical)
        let container = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: AppIdentity.popoverWidth,
            height: PanelPlacement.minimumContentHeight
        ))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        contentView = container
        hosting.frame = container.bounds
        metricsHostingView = hosting
        applyMetricsPopoverContract()
    }
}

import AppKit
import CodingAgentMetricsCore

enum PanelPlacement {
    static let minimumContentHeight: CGFloat = 240

    static func metricsContentSize(fittingHeight: CGFloat) -> NSSize {
        NSSize(
            width: AppIdentity.popoverWidth,
            height: max(fittingHeight, minimumContentHeight)
        )
    }

    static func resizedFrame(
        from frame: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        var resized = frame
        resized.size = NSSize(
            width: min(contentSize.width, visibleFrame.width),
            height: min(contentSize.height, visibleFrame.height)
        )
        let top = min(
            max(frame.maxY, visibleFrame.minY + resized.height),
            visibleFrame.maxY
        )
        resized.origin.y = top - resized.height
        return resized
    }
}

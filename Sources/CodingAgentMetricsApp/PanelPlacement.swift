import AppKit

enum PanelPlacement {
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

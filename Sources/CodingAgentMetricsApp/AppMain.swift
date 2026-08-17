import AppKit
import CodingAgentMetricsCore

@main
@MainActor
enum CodingAgentMetricsApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusItemController()
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}

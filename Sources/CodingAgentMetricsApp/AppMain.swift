import AppKit
import CodingAgentMetricsCore

@main
@MainActor
enum CodingAgentMetricsApp {
    static func main() {
        switch AppCommandLine.mode(arguments: Array(CommandLine.arguments.dropFirst())) {
        case .application:
            break
        case let .renderBenchmark(sampleCount):
            do {
                let statistics = try AppRenderBenchmark.measure(sampleCount: sampleCount)
                print(AppRenderBenchmark.report(statistics: statistics))
            } catch {
                FileHandle.standardError.write(Data("appkit_render=failed\n".utf8))
            }
            return
        case .invalidBenchmarkArguments:
            FileHandle.standardError.write(Data("usage: CodingAgentMetricsApp --benchmark-render <positive-sample-count>\n".utf8))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusItemController()
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}

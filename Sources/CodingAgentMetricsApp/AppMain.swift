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
        case let .snapshotSummary(outputPath, mutateOnePixel):
            do {
                try SummaryPopoverSnapshotRenderer.writePNG(
                    to: URL(fileURLWithPath: outputPath),
                    mutateOnePixel: mutateOnePixel
                )
                print(outputPath)
            } catch {
                FileHandle.standardError.write(Data("snapshot_render=failed\n".utf8))
            }
            return
        case let .snapshotSurface(surface, appearance, outputPath, mutateOnePixel):
            do {
                try SecondarySurfaceSnapshotRenderer.writePNG(
                    surface: surface,
                    appearance: appearance,
                    to: URL(fileURLWithPath: outputPath),
                    mutateOnePixel: mutateOnePixel
                )
                print(outputPath)
            } catch {
                FileHandle.standardError.write(Data("snapshot_render=failed\n".utf8))
            }
            return
        case let .snapshotContactSheet(appearance, outputPath):
            do {
                try SecondarySurfaceSnapshotRenderer.writeContactSheetPNG(
                    appearance: appearance,
                    to: URL(fileURLWithPath: outputPath)
                )
                print(outputPath)
            } catch {
                FileHandle.standardError.write(Data("snapshot_render=failed\n".utf8))
            }
            return
        case .invalidBenchmarkArguments:
            FileHandle.standardError.write(Data("usage: CodingAgentMetricsApp --benchmark-render <positive-sample-count>\n".utf8))
            return
        case .invalidSnapshotArguments:
            FileHandle.standardError.write(Data("usage: CodingAgentMetricsApp --snapshot-summary <png-path> [--mutate-one-pixel] | --snapshot-surface <settings|trends|data-diagnostics|about-updates> <light|dark> <png-path> [--mutate-one-pixel] | --snapshot-contact-sheet <light|dark> <png-path>\n".utf8))
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

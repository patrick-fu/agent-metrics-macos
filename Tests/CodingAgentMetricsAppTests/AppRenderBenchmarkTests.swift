import Testing
@testable import CodingAgentMetricsApp

struct AppRenderBenchmarkTests {
    @Test func benchmarkFlagDispatchesWithoutChangingOrdinaryLaunch() {
        #expect(AppCommandLine.mode(arguments: []) == .application)
        #expect(AppCommandLine.mode(arguments: ["--benchmark-render", "12"]) == .renderBenchmark(sampleCount: 12))
        #expect(AppCommandLine.mode(arguments: ["--benchmark-render", "0"]) == .invalidBenchmarkArguments)
    }

    @Test @MainActor
    func syntheticSummaryPopoverCompletesOneRealLayoutAndRenderSample() throws {
        let statistics = try AppRenderBenchmark.measure(sampleCount: 1, warmupCount: 0)

        #expect(statistics.sampleCount == 1)
        #expect(statistics.p50Milliseconds != nil)
        #expect(statistics.maximumMilliseconds != nil)
    }
}

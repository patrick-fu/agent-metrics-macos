import AppKit
import Foundation
import Testing
@testable import CodingAgentMetricsApp
import CodingAgentMetricsCore

struct SummaryPopoverSnapshotTests {
    @Test func snapshotFlagDispatchesWithoutChangingOrdinaryLaunch() {
        #expect(AppCommandLine.mode(arguments: ["--snapshot-summary", "/tmp/summary.png"]) == .snapshotSummary(outputPath: "/tmp/summary.png", mutateOnePixel: false))
        #expect(AppCommandLine.mode(arguments: ["--snapshot-summary", "/tmp/summary.png", "--mutate-one-pixel"]) == .snapshotSummary(outputPath: "/tmp/summary.png", mutateOnePixel: true))
        #expect(AppCommandLine.mode(arguments: ["--snapshot-summary"]) == .invalidSnapshotArguments)
    }

    @Test @MainActor
    func nativeSnapshotIs440PointsAt2x() throws {
        let bitmap = try SummaryPopoverSnapshotRenderer.renderBitmap()
        #expect(bitmap.pixelsWide == Int(AppIdentity.popoverWidth * 2))
        #expect(bitmap.pixelsHigh > 0)
        #expect(abs(bitmap.size.width - AppIdentity.popoverWidth) < 0.5)
    }

    @Test @MainActor
    func pixelComparatorDetectsOnePixelMutation() throws {
        let original = try SummaryPopoverSnapshotRenderer.renderBitmap()
        guard let mutated = original.copy() as? NSBitmapImageRep else {
            Issue.record("failed to copy snapshot bitmap")
            return
        }
        SummaryPopoverPixelComparator.mutateOnePixel(mutated)
        let comparison = SummaryPopoverPixelComparator.compare(actual: mutated, expected: original)
        #expect(!comparison.matches)
        #expect(comparison.changedPixelCount >= 1)
        #expect(comparison.width == original.pixelsWide)
        #expect(comparison.height == original.pixelsHigh)
    }

    @Test @MainActor
    func snapshotMatchesCommittedGolden() throws {
        let actual = try SummaryPopoverSnapshotRenderer.renderBitmap()
        let goldenURL = try #require(
            Bundle.module.url(forResource: "summary-popover-2x", withExtension: "png", subdirectory: "Fixtures/Golden")
                ?? Bundle.module.url(forResource: "summary-popover-2x", withExtension: "png")
        )
        let goldenData = try Data(contentsOf: goldenURL)
        let golden = try #require(NSBitmapImageRep(data: goldenData))
        let comparison = SummaryPopoverPixelComparator.compare(actual: actual, expected: golden)
        if !comparison.matches {
            if let diff = SummaryPopoverPixelComparator.diffImage(actual: actual, expected: golden),
               let diffPNG = diff.representation(using: .png, properties: [:]) {
                let diffURL = FileManager.default.temporaryDirectory.appendingPathComponent("summary-popover-diff.png")
                try diffPNG.write(to: diffURL)
                Issue.record("snapshot mismatch changed=\(comparison.changedPixelCount) maxDelta=\(comparison.maxChannelDelta) diff=\(diffURL.path)")
            }
        }
        #expect(actual.pixelsWide == golden.pixelsWide)
        #expect(actual.pixelsHigh == golden.pixelsHigh)
        #expect(comparison.matches)
    }
}

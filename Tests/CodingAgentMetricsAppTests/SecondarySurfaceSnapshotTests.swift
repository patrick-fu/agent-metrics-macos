import AppKit
import CodingAgentMetricsCore
import Foundation
import Testing
@testable import CodingAgentMetricsApp

@Suite(.serialized)
struct SecondarySurfaceSnapshotTests {
    @Test
    func snapshotSurfaceFlagDispatchesWithoutChangingOrdinaryLaunch() {
        #expect(
            AppCommandLine.mode(arguments: [
                "--snapshot-surface", "settings", "dark", "/tmp/settings.png",
            ]) == .snapshotSurface(
                surface: .settings,
                appearance: .dark,
                outputPath: "/tmp/settings.png",
                mutateOnePixel: false
            )
        )
        #expect(
            AppCommandLine.mode(arguments: [
                "--snapshot-surface", "trends", "light", "/tmp/trends.png", "--mutate-one-pixel",
            ]) == .snapshotSurface(
                surface: .trends,
                appearance: .light,
                outputPath: "/tmp/trends.png",
                mutateOnePixel: true
            )
        )
        #expect(AppCommandLine.mode(arguments: ["--snapshot-surface", "settings"]) == .invalidSnapshotArguments)
        #expect(
            AppCommandLine.mode(arguments: ["--snapshot-contact-sheet", "light", "/tmp/contact.png"])
                == .snapshotContactSheet(appearance: .light, outputPath: "/tmp/contact.png")
        )
        #expect(AppCommandLine.mode(arguments: []) == .application)
    }

    @Test @MainActor
    func snapshotRenderingUsesVolatileDefaultsAndStaysDeterministic() throws {
        let suite = SecondarySurfaceSnapshotRenderer.defaultsSuite
        #expect(
            UserDefaults.standard.persistentDomain(forName: suite) == nil,
            "the snapshot renderer must never own an on-disk preferences domain"
        )

        let defaults = SecondarySurfaceSnapshotRenderer.makeVolatileDefaults()
        #expect(defaults.object(forKey: EnhancedTelemetryController.defaultsKey) as? Bool == false)
        let preferences = DisplayPreferencesController(store: DisplayPreferencesStore(defaults: defaults))
        #expect(preferences.window == .threeMinutes)
        #expect(preferences.cadence == .thirtySeconds)
        #expect(UserDefaults.standard.persistentDomain(forName: suite) == nil)

        for surface in SnapshotSurface.allCases {
            for appearance in SnapshotAppearance.allCases {
                let first = try SecondarySurfaceSnapshotRenderer.renderBitmap(surface: surface, appearance: appearance)
                let second = try SecondarySurfaceSnapshotRenderer.renderBitmap(surface: surface, appearance: appearance)
                let comparison = SummaryPopoverPixelComparator.compare(actual: first, expected: second)
                #expect(comparison.changedPixelCount == 0, "\(surface) \(appearance) re-rendered differently")
            }
        }

        #expect(
            UserDefaults.standard.persistentDomain(forName: suite) == nil,
            "rendering surfaces must not persist preferences"
        )
    }

    @Test @MainActor
    func everySurfaceRendersAt440PointsAndWithin720PointsHigh() throws {
        for surface in SnapshotSurface.allCases {
            for appearance in SnapshotAppearance.allCases {
                let bitmap = try SecondarySurfaceSnapshotRenderer.renderBitmap(surface: surface, appearance: appearance)

                #expect(bitmap.pixelsWide == Int(AppIdentity.popoverWidth * 2), "\(surface) \(appearance)")
                #expect(bitmap.pixelsHigh > 0, "\(surface) \(appearance)")
                #expect(bitmap.pixelsHigh <= 1_440, "\(surface) \(appearance)")
                #expect(abs(bitmap.size.width - AppIdentity.popoverWidth) < 0.5, "\(surface) \(appearance)")
                #expect(bitmap.size.height <= 720, "\(surface) \(appearance)")
            }
        }
    }

    @Test @MainActor
    func everySurfaceMatchesItsCommittedLightAndDarkGolden() throws {
        for surface in SnapshotSurface.allCases {
            for appearance in SnapshotAppearance.allCases {
                let actual = try SecondarySurfaceSnapshotRenderer.renderBitmap(surface: surface, appearance: appearance)
                let goldenURL = try #require(
                    Bundle.module.url(
                        forResource: SecondarySurfaceSnapshotRenderer.goldenResourceName(surface: surface, appearance: appearance),
                        withExtension: "png",
                        subdirectory: "Fixtures/Golden"
                    )
                )
                let golden = try #require(NSBitmapImageRep(data: Data(contentsOf: goldenURL)))
                let comparison = SummaryPopoverPixelComparator.compare(actual: actual, expected: golden)

                if !comparison.matches,
                   let diff = SummaryPopoverPixelComparator.diffImage(actual: actual, expected: golden),
                   let diffPNG = diff.representation(using: .png, properties: [:]) {
                    let diffURL = FileManager.default.temporaryDirectory.appendingPathComponent("secondary-\(surface.rawValue)-\(appearance.rawValue)-diff.png")
                    try diffPNG.write(to: diffURL)
                    Issue.record("snapshot mismatch diff=\(diffURL.path)")
                }

                #expect(actual.pixelsWide == golden.pixelsWide, "\(surface) \(appearance)")
                #expect(actual.pixelsHigh == golden.pixelsHigh, "\(surface) \(appearance)")
                #expect(comparison.matches, "\(surface) \(appearance): changed=\(comparison.changedPixelCount) maxDelta=\(comparison.maxChannelDelta)")
            }
        }
    }

    @Test @MainActor
    func contactSheetsMatchCommittedGoldenPixelByPixel() throws {
        for appearance in SnapshotAppearance.allCases {
            let label = SecondarySurfaceSnapshotRenderer.contactSheetGoldenResourceName(appearance: appearance)
            // Swift Charts owns process-global first-composition state. Exercise the real
            // snapshot CLI in a fresh process so the golden gate matches production use
            // without depending on which other render test happened to run first.
            let sheet = try Self.renderContactSheetThroughCLI(appearance: appearance)
            let golden = try #require(NSBitmapImageRep(data: Data(contentsOf: goldenURL(named: label))))

            #expect(sheet.pixelsWide == Int(AppIdentity.popoverWidth * 4), "\(appearance)")
            #expect(sheet.pixelsHigh == golden.pixelsHigh, "\(appearance)")
            let comparison = SummaryPopoverPixelComparator.compare(actual: sheet, expected: golden)
            Self.recordMismatch(comparison, actual: sheet, expected: golden, label: label)
            #expect(comparison.matches, "\(appearance): changed=\(comparison.changedPixelCount) maxDelta=\(comparison.maxChannelDelta)")
        }
    }

    @Test @MainActor
    func contactSheetGoldenGateRejectsBlankOrDuplicatedTiles() throws {
        let appearance = SnapshotAppearance.light
        let label = SecondarySurfaceSnapshotRenderer.contactSheetGoldenResourceName(appearance: appearance)
        let sheet = try SecondarySurfaceSnapshotRenderer.renderContactSheet(appearance: appearance)
        let golden = try #require(NSBitmapImageRep(data: Data(contentsOf: goldenURL(named: label))))
        let settings = try SecondarySurfaceSnapshotRenderer.renderBitmap(surface: .settings, appearance: appearance)
        let trends = try SecondarySurfaceSnapshotRenderer.renderBitmap(surface: .trends, appearance: appearance)
        let tileWidth = min(settings.pixelsWide, trends.pixelsWide)
        let overlapHeight = min(settings.pixelsHigh, trends.pixelsHigh)

        let blanked = try Self.copy(sheet)
        Self.blank(in: blanked, x: 0, y: 0, width: settings.pixelsWide, height: settings.pixelsHigh)
        #expect(
            SummaryPopoverPixelComparator.compare(actual: blanked, expected: golden).matches == false,
            "a blank tile must fail the contact sheet gate"
        )

        let duplicated = try Self.copy(sheet)
        Self.copyTile(
            from: sheet,
            into: duplicated,
            sourceX: 0,
            targetX: settings.pixelsWide,
            width: tileWidth,
            height: overlapHeight
        )
        #expect(
            SummaryPopoverPixelComparator.compare(actual: duplicated, expected: golden).matches == false,
            "a duplicated settings tile must fail the contact sheet gate"
        )
    }

    @MainActor
    private func goldenURL(named name: String) throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "Fixtures/Golden"
            ),
            "\(name) is missing from the golden fixtures"
        )
    }

    private static func recordMismatch(
        _ comparison: SnapshotPixelComparison,
        actual: NSBitmapImageRep,
        expected: NSBitmapImageRep,
        label: String
    ) {
        guard !comparison.matches else { return }
        let changed = comparison.changedPixelCount
        let maxDelta = comparison.maxChannelDelta
        guard let diff = SummaryPopoverPixelComparator.diffImage(actual: actual, expected: expected),
              let png = diff.representation(using: .png, properties: [:]) else {
            Issue.record("snapshot mismatch \(label) changed=\(changed) maxDelta=\(maxDelta)")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-diff.png")
        try? png.write(to: url)
        Issue.record("snapshot mismatch \(label) changed=\(changed) maxDelta=\(maxDelta) diff=\(url.path)")
    }

    private static func renderContactSheetThroughCLI(
        appearance: SnapshotAppearance
    ) throws -> NSBitmapImageRep {
        let productsDirectory = Bundle.module.bundleURL.deletingLastPathComponent()
        let executable = productsDirectory.appendingPathComponent("CodingAgentMetricsApp")
        #expect(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "snapshot CLI executable is missing at \(executable.path)"
        )

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("secondary-contact-sheet-\(appearance.rawValue)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--snapshot-contact-sheet", appearance.rawValue, output.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let processOutput = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: processOutput))

        return try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
    }

    private static func copy(_ bitmap: NSBitmapImageRep) throws -> NSBitmapImageRep {
        guard let copy = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: bitmap.samplesPerPixel,
            hasAlpha: bitmap.hasAlpha,
            isPlanar: bitmap.isPlanar,
            colorSpaceName: bitmap.colorSpaceName,
            bytesPerRow: bitmap.bytesPerRow,
            bitsPerPixel: bitmap.bitsPerPixel
        ), let source = bitmap.bitmapData, let destination = copy.bitmapData else {
            throw SummaryPopoverSnapshotRendererError.renderSurfaceUnavailable
        }
        copy.size = bitmap.size
        destination.update(from: source, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return copy
    }

    private static func blank(in bitmap: NSBitmapImageRep, x: Int, y: Int, width: Int, height: Int) {
        guard let bytes = bitmap.bitmapData else { return }
        for row in y..<(y + height) {
            let rowStart = row * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
            memset(bytes.advanced(by: rowStart), 0, width * bitmap.samplesPerPixel)
        }
    }

    private static func copyTile(
        from source: NSBitmapImageRep,
        into destination: NSBitmapImageRep,
        sourceX: Int,
        targetX: Int,
        width: Int,
        height: Int
    ) {
        guard let sourceBytes = source.bitmapData, let destinationBytes = destination.bitmapData else { return }
        for row in 0..<height {
            let sourceOffset = row * source.bytesPerRow + sourceX * source.samplesPerPixel
            let destinationOffset = row * destination.bytesPerRow + targetX * destination.samplesPerPixel
            destinationBytes.advanced(by: destinationOffset)
                .update(from: sourceBytes.advanced(by: sourceOffset), count: width * source.samplesPerPixel)
        }
    }
}

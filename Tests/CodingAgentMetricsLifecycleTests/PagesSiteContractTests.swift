import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

struct PagesSiteContractTests {
    @Test func buildProducesAStandalonePagesArtifact() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-pages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try Self.runBuild(output: output)

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(".nojekyll").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("updates/appcast.xml").path))

        let enumerator = try #require(FileManager.default.enumerator(
            at: output,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        let resolvedOutputPath = output.resolvingSymlinksInPath().path
        let files = try enumerator.compactMap { item -> String? in
            let url = try #require(item as? URL)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return String(url.resolvingSymlinksInPath().path.dropFirst(resolvedOutputPath.count + 1))
        }
        #expect(Set(files) == [
            ".nojekyll",
            "assets/favicon.svg",
            "assets/summary-popover-2x.png",
            "index.html",
            "styles.css",
            "updates/appcast.xml",
        ])
    }

    @Test func productPageIsSearchableAccessibleAndComplete() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-pages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try Self.runBuild(output: output)
        #expect(result.status == 0, Comment(rawValue: result.output))

        let html = try String(contentsOf: output.appendingPathComponent("index.html"), encoding: .utf8)
        let css = try String(contentsOf: output.appendingPathComponent("styles.css"), encoding: .utf8)

        for fragment in [
            #"<html lang="en">"#,
            #"name="viewport" content="width=device-width, initial-scale=1""#,
            #"name="description""#,
            #"rel="canonical" href="https://patrick-fu.github.io/agent-metrics-macos/""#,
            "<header", "<nav", "<main", "<footer", "<h1",
            #"id="metrics""#, #"id="agents""#, #"id="privacy""#,
            #"id="install""#, #"id="faq""#,
            "Output Throughput", "Decode TPS", "Token Burn",
            "Codex", "Claude Code", "macOS 14", "Apple silicon",
            "stays on your Mac", "0.2.0", "build 5",
            #"src="assets/summary-popover-2x.png""#,
            #"alt="Agent Metrics menu bar summary showing an output throughput chart, token burn, active sessions, and data quality""#,
        ] {
            #expect(html.contains(fragment), "Missing page contract: \(fragment)")
        }

        let downloadURL = "https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.0/AgentMetrics-0.2.0.dmg"
        #expect(html.contains(#"href="\#(downloadURL)""#))
        #expect(html.contains(#"href="https://github.com/patrick-fu/agent-metrics-macos""#))
        #expect(html.contains(#"href="styles.css""#))
        #expect(!html.contains("<script"))
        #expect(!html.contains("cdn."))
        #expect(!html.contains("/Users/"))
        #expect(!html.contains("patrickfu@"))

        #expect(css.contains("@media (max-width:"))
        #expect(css.contains("@media (prefers-reduced-motion: reduce)"))
        #expect(css.contains(":focus-visible"))
    }

    @Test func builtSitePublishesTheRealScreenshotAndProductionFeedHistory() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-pages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try Self.runBuild(output: output)
        #expect(result.status == 0, Comment(rawValue: result.output))

        let publishedScreenshot = try Data(contentsOf: output.appendingPathComponent("assets/summary-popover-2x.png"))
        let goldenScreenshot = try Data(contentsOf: Self.projectRoot.appendingPathComponent("Tests/CodingAgentMetricsAppTests/Fixtures/Golden/summary-popover-2x.png"))
        #expect(publishedScreenshot == goldenScreenshot)

        let feed = try String(contentsOf: output.appendingPathComponent("updates/appcast.xml"), encoding: .utf8)
        #expect(feed.components(separatedBy: "<item>").count - 1 == 4)
        let currentRelease = try AppcastReleaseContract.validateFeed(feed, currentBuild: 4)
        #expect(currentRelease.version == 5)
        #expect(currentRelease.shortVersion == "0.2.0")
        #expect(currentRelease.archiveURL.absoluteString == "https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.0/AgentMetrics-0.2.0.dmg")
        #expect(currentRelease.archiveLength == 2_701_983)
        #expect(feed.contains(#"<sparkle:version>5</sparkle:version>"#))
        #expect(feed.contains(#"<sparkle:version>4</sparkle:version>"#))
        #expect(feed.contains(#"<sparkle:version>3</sparkle:version>"#))
        #expect(feed.contains(#"<sparkle:version>2</sparkle:version>"#))
        #expect(feed.range(of: #"sparkle:edSignature="[^"]+""#, options: .regularExpression) != nil)
        for historicalEnclosure in [
            #"url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.1.3/CodingAgentMetrics-0.1.3.dmg" length="2574280" type="application/octet-stream" sparkle:edSignature="prseBNybwNu4pcTktuUfSar4iJpZ6eXaXPluQIuWH3n4hocQxEpnyRguROoLssEtZ5DBbipFAlSFHEhc1u07BQ==""#,
            #"url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.1.2/CodingAgentMetrics-0.1.2.dmg" length="2570888" type="application/octet-stream" sparkle:edSignature="od7Rtu/O/Cz4QQsgoAU8vMgGH8pshQWLmuvnZnTlIwCX9JSA5M8yjbfc8K73t7868bUBK0rJMgnrnNcS5AtmAg==""#,
            #"url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.1.1/CodingAgentMetrics-0.1.1.dmg" length="2404227" type="application/octet-stream" sparkle:edSignature="5RM65Vujs3wS/bjBT4pJKzVqD43SPVV1lhJ1Au5L4bydSBhObmlh3n+94wF8XZU58exRcESdIbGCK5ur9L41Ag==""#,
        ] {
            #expect(feed.contains(historicalEnclosure))
        }
        #expect(throws: Never.self) { try XMLDocument(xmlString: feed) }
    }

    @Test func deploymentRequiresALocalLegacyCheckoutAndUsesWorktrees() throws {
        let script = Self.projectRoot.appendingPathComponent("scripts/deploy-pages.sh")
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "--help"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let help = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0, Comment(rawValue: help))
        #expect(help.contains("--legacy-repo PATH"))
        #expect(help.contains("--publish"))

        let source = try String(contentsOf: script, encoding: .utf8)
        #expect(source.contains("worktree add"))
        #expect(source.contains("primary-pages"))
        #expect(source.contains("legacy-pages"))
        #expect(source.contains("updates/appcast.xml"))
        #expect(!source.contains("gh api"))
        #expect(!source.contains("gh workflow"))
    }

    @Test func deploymentPinsBothRepositoryOriginsExactly() throws {
        let source = try String(contentsOf: Self.projectRoot.appendingPathComponent("scripts/deploy-pages.sh"), encoding: .utf8)

        #expect(source.contains("remote get-url origin"))
        #expect(source.contains(#"github.com:patrick-fu/$expected.git"#))
        #expect(source.contains(#"https://github.com/patrick-fu/$expected.git"#))
        #expect(source.contains("require_origin \"$root\" agent-metrics-macos primary"))
        #expect(source.contains("require_origin \"$legacy_repo\" coding-agent-metrics legacy"))
    }

    @Test func buildUsesAFileAllowlistAndRejectsUnexpectedWebsiteFiles() throws {
        let source = try String(contentsOf: Self.projectRoot.appendingPathComponent("scripts/build-site.sh"), encoding: .utf8)

        #expect(source.contains("website contains non-allowlisted files"))
        #expect(source.contains("assets/favicon.svg|assets/summary-popover-2x.png|index.html|styles.css|updates/appcast.xml"))
        #expect(source.contains("cp \"$root/website/index.html\""))
        #expect(!source.contains("cp -R \"$root/website/.\""))
    }

    @Test func releaseNoteUsesAAContrastColor() throws {
        let css = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/styles.css"), encoding: .utf8)

        #expect(css.contains(".release-note {"))
        #expect(css.contains("color: #5f6368"))
    }

    @Test func publishPreflightsTheReleaseDMGAndPushesPrimaryBeforeLegacy() throws {
        let source = try String(contentsOf: Self.projectRoot.appendingPathComponent("scripts/deploy-pages.sh"), encoding: .utf8)

        #expect(source.contains("release_urls=\"$(sed -n"))
        #expect(source.contains("release_url_count"))
        #expect(source.contains("curl -L -sS -o /dev/null -w '%{http_code}' \"$release_url\""))
        #expect(source.contains("2??"))

        let primaryPush = try #require(source.range(of: "git -C \"$primary_worktree\" push origin gh-pages:gh-pages"))
        let legacyPush = try #require(source.range(of: "git -C \"$legacy_worktree\" push origin gh-pages:gh-pages"))
        #expect(primaryPush.lowerBound < legacyPush.lowerBound)
    }

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func runBuild(output: URL) throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            projectRoot.appendingPathComponent("scripts/build-site.sh").path,
            output.path,
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

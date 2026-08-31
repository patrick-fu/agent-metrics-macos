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
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("zh.html").path))
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
            "assets/og-image.png",
            "assets/secondary-surfaces-contact-sheet-dark-2x.png",
            "assets/secondary-surfaces-contact-sheet-light-2x.png",
            "assets/summary-popover-2x.png",
            "index.html",
            "og-card.html",
            "robots.txt",
            "site.webmanifest",
            "sitemap.xml",
            "styles.css",
            "updates/appcast.xml",
            "zh.html",
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
            #"rel="alternate" hreflang="zh-CN" href="https://patrick-fu.github.io/agent-metrics-macos/zh.html""#,
            #"name="twitter:card" content="summary_large_image""#,
            #"application/ld+json"#,
            "<header", "<nav", "<main", "<footer", "<h1",
            #"id="metrics""#, #"id="surfaces""#, #"id="agents""#, #"id="privacy""#,
            #"id="install""#, #"id="faq""#,
            "Output Throughput", "Decode TPS", "Token Burn",
            "Codex", "Claude Code", "macOS 14", "Apple silicon",
            "3, 5, or 10 minute", "600-second", "stable Model Call IDs",
            "Enhanced Telemetry", "loopback", "unauthenticated", "7-day",
            #"src="assets/summary-popover-2x.png""#,
            #"src="assets/secondary-surfaces-contact-sheet-light-2x.png""#,
            #"srcset="assets/secondary-surfaces-contact-sheet-dark-2x.png""#,
            #"width="1760" height="2574""#,
            #"width="880" height="1438""#,
            #"alt="Agent Metrics menu bar summary showing an output throughput chart, token burn, active sessions, and data quality""#,
        ] {
            #expect(html.contains(fragment), "Missing page contract: \(fragment)")
        }

        let release = Self.latestRelease()
        let downloadURL = release.url
        #expect(html.contains(#"href="\#(downloadURL)""#))
        #expect(html.contains("Version \(release.version) · build \(release.build)"))
        #expect(html.contains(#"href="https://github.com/patrick-fu/agent-metrics-macos""#))
        #expect(html.contains(#"href="styles.css""#))
        #expect(!html.contains("<script src"))
        #expect(!html.contains("application/javascript"))
        #expect(!html.contains("cdn."))
        #expect(!html.contains("/Users/"))
        #expect(!html.contains("patrickfu@"))
        #expect(!html.contains("{{LATEST_"))

        let zh = try String(contentsOf: output.appendingPathComponent("zh.html"), encoding: .utf8)
        for fragment in [
            #"<html lang="zh-CN">"#,
            #"rel="canonical" href="https://patrick-fu.github.io/agent-metrics-macos/zh.html""#,
            #"rel="alternate" hreflang="en" href="https://patrick-fu.github.io/agent-metrics-macos/""#,
            #"id="metrics""#, #"id="surfaces""#, #"id="agents""#, #"id="privacy""#, #"id="install""#, #"id="faq""#,
            "输出吞吐", "解码 TPS", "Token Burn", "增强遥测", "回环", "未鉴权",
        ] {
            #expect(zh.contains(fragment), "Missing Chinese page contract: \(fragment)")
        }
        #expect(zh.contains(#"href="\#(downloadURL)""#))
        #expect(zh.contains("版本 \(release.version) · build \(release.build)"))
        #expect(!zh.contains("{{LATEST_"))

        #expect(css.contains("@media (max-width:"))
        #expect(css.contains("@media (prefers-color-scheme: dark)"))
        #expect(css.contains("@media (prefers-reduced-motion: reduce)"))
        #expect(css.contains(":focus-visible"))
        #expect(css.contains("img { display:block; max-width:100%; height:auto; }"))
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
        #expect(feed.components(separatedBy: "<item>").count - 1 == 6)
        let currentRelease = try AppcastReleaseContract.validateFeed(feed, currentBuild: 6)
        #expect(currentRelease.version == 7)
        #expect(currentRelease.shortVersion == "0.2.2")
        #expect(currentRelease.archiveURL.absoluteString == "https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.2/AgentMetrics-0.2.2.dmg")
        #expect(currentRelease.archiveLength == 2_895_729)
        #expect(feed.contains(#"<sparkle:version>7</sparkle:version>"#))
        #expect(feed.contains(#"<sparkle:version>6</sparkle:version>"#))
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
        let manifest = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/site-manifest.txt"), encoding: .utf8)

        #expect(source.contains("website contains non-allowlisted files"))
        #expect(source.contains("site-manifest.txt"))
        #expect(source.contains("is_safe_source"))
        #expect(source.contains("is_safe_relative_path"))
        #expect(source.contains("LATEST_VERSION"))
        #expect(source.contains(#"gsub(/&/, "\\\\&", rendered_url)"#))
        #expect(manifest.contains("index.html.in index.html"))
        #expect(manifest.contains("zh.html.in zh.html"))
        #expect(manifest.contains("updates/appcast.xml updates/appcast.xml"))
        #expect(manifest.contains("assets/og-image.png assets/og-image.png"))
        #expect(manifest.contains("assets/secondary-surfaces-contact-sheet-light-2x.png assets/secondary-surfaces-contact-sheet-light-2x.png"))
        #expect(manifest.contains("assets/secondary-surfaces-contact-sheet-dark-2x.png assets/secondary-surfaces-contact-sheet-dark-2x.png"))
        #expect(!source.contains("cp -R \"$root/website/.\""))
    }

    @Test func releaseNoteUsesAAContrastColor() throws {
        let css = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/styles.css"), encoding: .utf8)

        #expect(css.contains(".release-note,.section-note,.quality-note"))
        #expect(css.contains("--muted:#596170"))
        #expect(css.contains(":focus-visible { outline-color:var(--accent); }"))
        #expect(css.contains(".button { color:#0c1017; }"))
    }

    @Test func socialMetadataReservesALandscapeOGArtifactWithoutTreatingThePortraitAppShotAsOne() throws {
        let english = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/index.html.in"), encoding: .utf8)
        let chinese = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/zh.html.in"), encoding: .utf8)
        let cardSource = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/og-card.html"), encoding: .utf8)
        let styles = try String(contentsOf: Self.projectRoot.appendingPathComponent("website/styles.css"), encoding: .utf8)

        for page in [english, chinese] {
            #expect(page.contains("assets/og-image.png"))
            #expect(!page.contains("og:image\" content=\"https://patrick-fu.github.io/agent-metrics-macos/assets/summary-popover-2x.png"))
        }
        // The rendered 1200×630 PNG is produced by the release owner and deliberately
        // is not fabricated by the source build or substituted with the portrait screenshot.
        #expect(cardSource.contains("width=1200"))
        #expect(cardSource.contains(#"src="assets/summary-popover-2x.png""#))
        #expect(styles.contains(".og-card-page { display:grid; width:1200px; height:630px;"))
    }

    @Test func publishDerivesAndPreflightsTheLatestReleaseDMGBeforePushingPrimaryThenLegacy() throws {
        let source = try String(contentsOf: Self.projectRoot.appendingPathComponent("scripts/deploy-pages.sh"), encoding: .utf8)

        #expect(source.contains("latest_item"))
        #expect(source.contains("latest appcast item"))
        #expect(source.contains("expected_filename=\"AgentMetrics-${short_version}.dmg\""))
        #expect(source.contains("validate-appcast.sh"))
        #expect(source.contains("AppcastReleaseContract.swift"))
        #expect(source.contains("curl -q -L -sS -D \"$headers\" -O -J"))
        #expect(source.contains("byte length mismatch"))
        #expect(source.contains("--preflight-site PATH"))

        let primaryPush = try #require(source.range(of: "git -C \"$primary_worktree\" push origin gh-pages:gh-pages"))
        let legacyPush = try #require(source.range(of: "git -C \"$legacy_worktree\" push origin gh-pages:gh-pages"))
        #expect(primaryPush.lowerBound < legacyPush.lowerBound)
    }

    @Test func releasePreflightReadsOneNewestAppcastItemInsteadOfHardcodingARelease() throws {
        let source = try String(contentsOf: Self.projectRoot.appendingPathComponent("scripts/deploy-pages.sh"), encoding: .utf8)

        #expect(source.contains("single_value"))
        #expect(source.contains("latest appcast item must contain exactly one $label"))
        #expect(source.contains("enclosure URL"))
        #expect(source.contains("latest appcast URL mismatch"))
        #expect(!source.contains("AgentMetrics-0.2.0.dmg"))
        #expect(!source.contains("v0.2.0"))
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

    private static func latestRelease() -> (version: String, build: String, url: String) {
        let appcast = try! String(contentsOf: projectRoot.appendingPathComponent("website/updates/appcast.xml"), encoding: .utf8)
        let firstItem = appcast.components(separatedBy: "<item>")[1].components(separatedBy: "</item>")[0]
        func value(_ pattern: String) -> String {
            let expression = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(firstItem.startIndex..., in: firstItem)
            let match = expression.firstMatch(in: firstItem, range: range)!
            return String(firstItem[Range(match.range(at: 1), in: firstItem)!])
        }
        return (
            value(#"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"#),
            value(#"<sparkle:version>([^<]+)</sparkle:version>"#),
            value(#"<enclosure url="([^"]+)""#)
        )
    }
}

import CryptoKit
import Foundation
import Testing

struct PagesDeploymentContractTests {
    @Test func appMetadataTargetsTheNextPublicBetaRelease() throws {
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.root.appendingPathComponent("Sources/CodingAgentMetricsApp/Info.plist")),
            format: nil
        ) as? [String: Any]

        #expect(info?["CFBundleShortVersionString"] as? String == "0.2.2")
        #expect(info?["CFBundleVersion"] as? String == "7")
    }

    @Test func preflightUsesTheLatestAppcastItemAndValidatesTheDownloadedArtifact() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let signingFixture = try Self.makeSigningFixture(payload: "twelve-bytes")
        let project = try Self.makePreflightProject(
            in: temporaryDirectory,
            publicKey: signingFixture.publicKey
        )

        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12,
            latestEdSignature: signingFixture.signature
        )
        let curlBin = try Self.makeCurlStub(in: temporaryDirectory)

        let result = try Self.runPreflight(
            site: site,
            curlBin: curlBin,
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
            ],
            project: project
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("release preflight passed: 0.2.1 (6), AgentMetrics-0.2.1.dmg, 12 bytes"))
    }

    @Test func preflightRejectsAOneByteChangedDownloadedDMGAfterCurl() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let signingFixture = try Self.makeSigningFixture(payload: "twelve-bytes")
        let project = try Self.makePreflightProject(in: temporaryDirectory, publicKey: signingFixture.publicKey)
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12,
            latestEdSignature: signingFixture.signature
        )
        let curlMarker = temporaryDirectory.appendingPathComponent("curl-invoked")

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelvf-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
                "CURL_STUB_MARKER": curlMarker.path,
            ],
            project: project
        )

        #expect(result.status != 0)
        #expect(result.output.contains("signature verification failed"), Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test func preflightRejectsAnIncorrectEdDSASignature() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let signingFixture = try Self.makeSigningFixture(payload: "twelve-bytes")
        let project = try Self.makePreflightProject(in: temporaryDirectory, publicKey: signingFixture.publicKey)
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12,
            latestEdSignature: Data(repeating: 0, count: 64).base64EncodedString()
        )

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
            ],
            project: project
        )

        #expect(result.status != 0)
        #expect(result.output.contains("signature verification failed"), Comment(rawValue: result.output))
    }

    @Test func preflightRejectsAValidSignatureForTheWrongPublicKey() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let signingFixture = try Self.makeSigningFixture(payload: "twelve-bytes")
        let unrelatedFixture = try Self.makeSigningFixture(payload: "unrelated-payload")
        let project = try Self.makePreflightProject(in: temporaryDirectory, publicKey: unrelatedFixture.publicKey)
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12,
            latestEdSignature: signingFixture.signature
        )

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
            ],
            project: project
        )

        #expect(result.status != 0)
        #expect(result.output.contains("signature verification failed"), Comment(rawValue: result.output))
    }

    @Test(arguments: [
        (
            "wrong final filename",
            [
                "CURL_STUB_FILENAME": "unexpected.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/unexpected.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
            ],
            "final filename mismatch"
        ),
        (
            "wrong byte length",
            [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "too-short",
                "CURL_STUB_HTTP_STATUS": "200",
            ],
            "byte length mismatch"
        ),
        (
            "non-success HTTP status",
            [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "404",
            ],
            "HTTP 404"
        ),
    ])
    func preflightFailsClosedForMismatchedPublicArtifact(
        _ name: String,
        environment: [String: String],
        expectedError: String
    ) throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12
        )
        let curlBin = try Self.makeCurlStub(in: temporaryDirectory)

        let result = try Self.runPreflight(site: site, curlBin: curlBin, environment: environment)

        #expect(result.status != 0)
        #expect(result.output.contains(expectedError), Comment(rawValue: result.output))
    }

    @Test(arguments: [
        ("third-party HTTPS host", "https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.1/AgentMetrics-0.2.1.dmg", "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg"),
        ("tag differs from short version", "/releases/download/v0.2.1/AgentMetrics-0.2.1.dmg", "/releases/download/v0.2.0/AgentMetrics-0.2.1.dmg"),
    ])
    func preflightRejectsANewestArtifactURLThatIsNotTheMatchingPublicGitHubRelease(
        _ name: String,
        source: String,
        replacement: String
    ) throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12
        )
        let appcast = site.appendingPathComponent("updates/appcast.xml")
        let contents = try String(contentsOf: appcast, encoding: .utf8)
        try contents.replacingOccurrences(of: source, with: replacement)
            .write(to: appcast, atomically: true, encoding: .utf8)
        let curlMarker = temporaryDirectory.appendingPathComponent("curl-invoked")

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
                "CURL_STUB_MARKER": curlMarker.path,
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("latest appcast URL mismatch"), Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test(arguments: [
        ("missing minimum OS", "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", ""),
        ("wrong minimum OS", "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", "<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>"),
    ])
    func preflightRejectsANewestItemWithoutTheSupportedMinimumOS(
        _ name: String,
        source: String,
        replacement: String
    ) throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12
        )
        let appcast = site.appendingPathComponent("updates/appcast.xml")
        let contents = try String(contentsOf: appcast, encoding: .utf8)
        try contents.replacingOccurrences(of: source, with: replacement)
            .write(to: appcast, atomically: true, encoding: .utf8)
        let curlMarker = temporaryDirectory.appendingPathComponent("curl-invoked")

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
                "CURL_STUB_MARKER": curlMarker.path,
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("minimum macOS mismatch"), Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test func preflightRejectsMultipleEnclosuresInTheLatestAppcastItem() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12
        )
        let appcast = site.appendingPathComponent("updates/appcast.xml")
        let duplicateEnclosure = #"<enclosure url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.1/AgentMetrics-0.2.1-alt.dmg" length="12" type="application/octet-stream" sparkle:edSignature="synthetic"/>"#
        let contents = try String(contentsOf: appcast, encoding: .utf8)
        try contents.replacingOccurrences(of: "</item>", with: duplicateEnclosure + "</item>")
            .write(to: appcast, atomically: true, encoding: .utf8)

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("production update contract"), Comment(rawValue: result.output))
    }

    @Test(arguments: [
        ("missing latest signature", #"sparkle:edSignature="synthetic""#, #"sparkle:edSignature="""#),
        ("missing historical signature", #"sparkle:edSignature="historical""#, #"sparkle:edSignature="""#),
        ("beta historical channel", "<sparkle:version>5</sparkle:version>", "<sparkle:channel>beta</sparkle:channel><sparkle:version>5</sparkle:version>"),
        ("insecure historical URL", "https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.0/AgentMetrics-0.2.0.dmg", "http://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.0/AgentMetrics-0.2.0.dmg"),
        ("duplicate historical build", "<sparkle:version>5</sparkle:version>", "<sparkle:version>6</sparkle:version>"),
        ("out-of-order historical build", "<sparkle:version>5</sparkle:version>", "<sparkle:version>7</sparkle:version>"),
    ])
    func preflightRejectsAFeedThatViolatesTheProductionUpdateContract(
        _ name: String,
        source: String,
        replacement: String
    ) throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let site = try Self.makeSite(
            in: temporaryDirectory,
            shortVersion: "0.2.1",
            build: "6",
            length: 12
        )
        let appcast = site.appendingPathComponent("updates/appcast.xml")
        let contents = try String(contentsOf: appcast, encoding: .utf8)
        try contents.replacingOccurrences(of: source, with: replacement)
            .write(to: appcast, atomically: true, encoding: .utf8)
        let curlMarker = temporaryDirectory.appendingPathComponent("curl-invoked")

        let result = try Self.runPreflight(
            site: site,
            curlBin: try Self.makeCurlStub(in: temporaryDirectory),
            environment: [
                "CURL_STUB_FILENAME": "AgentMetrics-0.2.1.dmg",
                "CURL_STUB_EFFECTIVE_URL": "https://downloads.example.invalid/AgentMetrics-0.2.1.dmg",
                "CURL_STUB_PAYLOAD": "twelve-bytes",
                "CURL_STUB_HTTP_STATUS": "200",
                "CURL_STUB_MARKER": curlMarker.path,
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("production update contract"), Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    @Test(arguments: [
        ("absolute source", "/etc/passwd output.html"),
        ("traversing source", "../outside.html output.html"),
        ("doubled separator source", "assets//safe.html output.html"),
        ("traversing destination", "safe.html ../output.html"),
        ("absolute destination", "safe.html /output.html"),
        ("doubled separator destination", "safe.html nested//output.html"),
        ("outside symlink source", "outside-link.html output.html"),
    ])
    func buildSiteRejectsUnsafeManifestSourceAndDestinationPaths(
        _ name: String,
        manifestEntry: String
    ) throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let project = temporaryDirectory.appendingPathComponent("project", isDirectory: true)
        let scripts = project.appendingPathComponent("scripts", isDirectory: true)
        let website = project.appendingPathComponent("website", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: website.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: website.appendingPathComponent("updates"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.root.appendingPathComponent("scripts/build-site.sh"),
            to: scripts.appendingPathComponent("build-site.sh")
        )
        try "safe".write(to: website.appendingPathComponent("safe.html"), atomically: true, encoding: .utf8)
        try "safe".write(to: website.appendingPathComponent("assets/safe.html"), atomically: true, encoding: .utf8)
        try "outside".write(to: temporaryDirectory.appendingPathComponent("outside.html"), atomically: true, encoding: .utf8)
        if name == "outside symlink source" {
            try FileManager.default.createSymbolicLink(
                atPath: website.appendingPathComponent("outside-link.html").path,
                withDestinationPath: temporaryDirectory.appendingPathComponent("outside.html").path
            )
        }
        try "<rss><channel><item><sparkle:version>6</sparkle:version><sparkle:shortVersionString>0.2.1</sparkle:shortVersionString><enclosure url=\"https://downloads.example.invalid/AgentMetrics-0.2.1.dmg\"/></item></channel></rss>"
            .write(to: website.appendingPathComponent("updates/appcast.xml"), atomically: true, encoding: .utf8)
        try "# source destination\nsafe.html safe.html\nassets/safe.html assets/safe.html\nupdates/appcast.xml updates/appcast.xml\n\(manifestEntry)\n"
            .write(to: website.appendingPathComponent("site-manifest.txt"), atomically: true, encoding: .utf8)

        let result = try Self.runBuildSite(
            script: scripts.appendingPathComponent("build-site.sh"),
            output: temporaryDirectory.appendingPathComponent("output")
        )

        #expect(result.status != 0)
        #expect(result.output.contains("unsafe manifest"), Comment(rawValue: result.output))
    }

    @Test func normalDryRunNeverInvokesCurl() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let curlBin = try Self.makeCurlStub(in: temporaryDirectory)
        let curlMarker = temporaryDirectory.appendingPathComponent("curl-invoked")

        let result = try Self.run(
            arguments: ["--legacy-repo", temporaryDirectory.appendingPathComponent("missing").path],
            environment: [
                "PATH": curlBin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
                "CURL_STUB_MARKER": curlMarker.path,
            ]
        )

        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: curlMarker.path))
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-pages-preflight-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeSite(
        in temporaryDirectory: URL,
        shortVersion: String,
        build: String,
        length: Int,
        latestEdSignature: String = "synthetic"
    ) throws -> URL {
        let site = temporaryDirectory.appendingPathComponent("site", isDirectory: true)
        let updates = site.appendingPathComponent("updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let appcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
        <item>
        <sparkle:version>\(build)</sparkle:version>
        <sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v\(shortVersion)/AgentMetrics-\(shortVersion).dmg" length="\(length)" type="application/octet-stream" sparkle:edSignature="\(latestEdSignature)"/>
        </item>
        <item>
        <sparkle:version>5</sparkle:version>
        <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
        <enclosure url="https://github.com/patrick-fu/agent-metrics-macos/releases/download/v0.2.0/AgentMetrics-0.2.0.dmg" length="11" type="application/octet-stream" sparkle:edSignature="historical"/>
        </item>
        </channel></rss>
        """
        try appcast.write(to: updates.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)
        return site
    }

    private static func makeSigningFixture(payload: String) throws -> (publicKey: String, signature: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payloadData = Data(payload.utf8)
        return (
            privateKey.publicKey.rawRepresentation.base64EncodedString(),
            try privateKey.signature(for: payloadData).base64EncodedString()
        )
    }

    private static func makePreflightProject(in temporaryDirectory: URL, publicKey: String) throws -> URL {
        let project = temporaryDirectory.appendingPathComponent("preflight-project", isDirectory: true)
        let scripts = project.appendingPathComponent("scripts", isDirectory: true)
        let lifecycle = project.appendingPathComponent("Sources/CodingAgentMetricsLifecycle", isDirectory: true)
        let validator = project.appendingPathComponent("Sources/CodingAgentMetricsAppcastValidator", isDirectory: true)
        let app = project.appendingPathComponent("Sources/CodingAgentMetricsApp", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lifecycle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validator, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        for path in ["scripts/deploy-pages.sh", "scripts/validate-appcast.sh", "Sources/CodingAgentMetricsLifecycle/AppcastReleaseContract.swift", "Sources/CodingAgentMetricsAppcastValidator/main.swift"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(path), to: project.appendingPathComponent(path))
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>SUPublicEDKey</key><string>\(publicKey)</string></dict></plist>
        """.write(
            to: app.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        return project
    }

    private static func makeCurlStub(in temporaryDirectory: URL) throws -> URL {
        let bin = temporaryDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("curl")
        let source = """
        #!/bin/sh
        set -eu
        if [ -n "${CURL_STUB_REQUIRE_FIRST_ARG:-}" ] && [ "$1" != "$CURL_STUB_REQUIRE_FIRST_ARG" ]; then
            exit 96
        fi
        headers=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -D) headers="$2"; shift 2 ;;
                -w) shift 2 ;;
                *) shift ;;
            esac
        done
        : "${CURL_STUB_FILENAME:?}"
        : "${CURL_STUB_EFFECTIVE_URL:?}"
        : "${CURL_STUB_PAYLOAD:?}"
        : "${CURL_STUB_HTTP_STATUS:?}"
        if [ -n "${CURL_STUB_MARKER:-}" ]; then touch "$CURL_STUB_MARKER"; fi
        printf 'HTTP/1.1 %s Stub\\nContent-Disposition: attachment; filename="%s"\\n\\n' "$CURL_STUB_HTTP_STATUS" "$CURL_STUB_FILENAME" > "$headers"
        printf '%s' "$CURL_STUB_PAYLOAD" > "$CURL_STUB_FILENAME"
        printf '%s\\n%s\\n%s\\n' "$CURL_STUB_HTTP_STATUS" "${#CURL_STUB_PAYLOAD}" "$CURL_STUB_EFFECTIVE_URL"
        """
        try source.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return bin
    }

    private static func runPreflight(
        site: URL,
        curlBin: URL,
        environment: [String: String],
        project: URL = root
    ) throws -> (status: Int32, output: String) {
        var combinedEnvironment = environment
        combinedEnvironment["PATH"] = curlBin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        combinedEnvironment["CURL_STUB_REQUIRE_FIRST_ARG"] = "-q"
        return try run(arguments: ["--preflight-site", site.path], environment: combinedEnvironment, project: project)
    }

    private static func runBuildSite(script: URL, output: URL) throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, output.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private static func run(
        arguments: [String],
        environment additions: [String: String],
        project: URL = root
    ) throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [project.appendingPathComponent("scripts/deploy-pages.sh").path] + arguments
        process.currentDirectoryURL = project
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

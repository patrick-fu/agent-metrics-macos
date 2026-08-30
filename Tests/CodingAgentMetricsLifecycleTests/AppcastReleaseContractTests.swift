import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

struct AppcastReleaseContractTests {
    @Test func feedSelectsTheHighestStableBuildFromDescendingHistory() throws {
        let release = try AppcastReleaseContract.validateFeed(
            Self.appcastFeedXML([
                Self.itemXML(version: "4", shortVersion: "0.1.4"),
                Self.itemXML(version: "3", shortVersion: "0.1.3"),
                Self.itemXML(version: "2", shortVersion: "0.1.2"),
            ]),
            currentBuild: 1
        )

        #expect(release.version == 4)
        #expect(release.shortVersion == "0.1.4")
    }

    @Test func feedAllowsHistoricalBuildsAndValidatesTheNextRelease() throws {
        let release = try AppcastReleaseContract.validateFeed(
            Self.appcastFeedXML([
                Self.itemXML(version: "5", shortVersion: "0.2.0"),
                Self.itemXML(version: "4", shortVersion: "0.1.4"),
                Self.itemXML(version: "3", shortVersion: "0.1.3"),
                Self.itemXML(version: "2", shortVersion: "0.1.2"),
            ]),
            currentBuild: 4
        )

        #expect(release.version == 5)
        #expect(release.shortVersion == "0.2.0")
    }

    @Test(arguments: [
        ["4", "5", "3"],
        ["5", "4", "4"],
    ])
    func feedRejectsBuildsThatAreNotStrictlyDescending(_ builds: [String]) {
        #expect(throws: AppcastReleaseContractError.nonIncreasingBuilds) {
            try AppcastReleaseContract.validateFeed(
                Self.appcastFeedXML(builds.map { Self.itemXML(version: $0, shortVersion: "0.1.\($0)") }),
                currentBuild: 1
            )
        }
    }

    @Test func feedRejectsAnItemWithoutAnEdDSASignature() {
        #expect(throws: AppcastReleaseContractError.missingEdDSASignature) {
            try AppcastReleaseContract.validateFeed(
                Self.appcastFeedXML([
                    Self.itemXML(version: "5", shortVersion: "0.2.0"),
                    Self.itemXML(version: "4", shortVersion: "0.1.4", edSignature: ""),
                    Self.itemXML(version: "3", shortVersion: "0.1.3"),
                ]),
                currentBuild: 4
            )
        }
    }

    @Test func feedRejectsAnItemWithAnInsecureArchiveURL() {
        #expect(throws: AppcastReleaseContractError.insecureEnclosureURL) {
            try AppcastReleaseContract.validateFeed(
                Self.appcastFeedXML([
                    Self.itemXML(version: "5", shortVersion: "0.2.0"),
                    Self.itemXML(version: "4", shortVersion: "0.1.4", enclosureURL: "http://example.invalid/AgentMetrics-4.dmg"),
                    Self.itemXML(version: "3", shortVersion: "0.1.3"),
                ]),
                currentBuild: 4
            )
        }
    }

    @Test func feedRejectsDuplicateItemMetadata() {
        let duplicateVersionItem = Self.itemXML(version: "5", shortVersion: "0.2.0").replacingOccurrences(
            of: "<sparkle:version>5</sparkle:version>",
            with: "<sparkle:version>5</sparkle:version><sparkle:version>5</sparkle:version>"
        )

        #expect(throws: AppcastReleaseContractError.invalidAppcast) {
            try AppcastReleaseContract.validateFeed(
                Self.appcastFeedXML([duplicateVersionItem, Self.itemXML(version: "4", shortVersion: "0.1.4")]),
                currentBuild: 4
            )
        }
    }

    @Test func feedRequiresTheHighestBuildToAdvanceTheLastGoodBuild() {
        #expect(throws: AppcastReleaseContractError.versionRollback) {
            try AppcastReleaseContract.validateFeed(
                Self.appcastFeedXML([
                    Self.itemXML(version: "4", shortVersion: "0.1.4"),
                    Self.itemXML(version: "3", shortVersion: "0.1.3"),
                    Self.itemXML(version: "2", shortVersion: "0.1.2"),
                ]),
                currentBuild: 4
            )
        }
    }

    @Test func acceptsAStableHTTPSAppcastWithEdDSASigning() throws {
        let release = try AppcastReleaseContract.validate(
            Self.appcastXML(
                version: "2",
                enclosureURL: "https://example.invalid/AgentMetrics-2.dmg",
                length: "42",
                edSignature: "synthetic-ed25519-signature"
            ),
            currentBuild: 1
        )

        #expect(release.version == 2)
        #expect(release.archiveLength == 42)
        #expect(release.archiveSigning == .sparkleEdDSA)
        #expect(release.codeSigning == .developerIDRequired)
    }

    @Test func acceptsOfficialSparkleMetadataWithAnArbitraryNamespacePrefix() throws {
        let xml = """
        <rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <s:version>2</s:version>
        <s:shortVersionString>0.2.0</s:shortVersionString>
        <enclosure url="https://example.invalid/AgentMetrics-2.dmg" length="42" s:edSignature="synthetic-ed25519-signature" />
        </item></channel></rss>
        """

        let release = try AppcastReleaseContract.validate(xml, currentBuild: 1)

        #expect(release.version == 2)
        #expect(release.shortVersion == "0.2.0")
    }

    @Test func rejectsAChannelInTheOfficialSparkleNamespaceRegardlessOfPrefix() {
        let xml = """
        <rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <s:version>2</s:version><s:channel>beta</s:channel>
        <enclosure url="https://example.invalid/AgentMetrics-2.dmg" length="42" s:edSignature="synthetic-ed25519-signature" />
        </item></channel></rss>
        """

        #expect(throws: AppcastReleaseContractError.nonStableChannel) {
            try AppcastReleaseContract.validate(xml, currentBuild: 1)
        }
    }

    @Test func feedRejectsAChannelInTheOfficialSparkleNamespaceRegardlessOfPrefix() {
        let xml = """
        <rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><s:version>3</s:version><s:shortVersionString>0.2.1</s:shortVersionString><s:channel>beta</s:channel><enclosure url="https://example.invalid/AgentMetrics-3.dmg" length="42" s:edSignature="synthetic-ed25519-signature" /></item>
        <item><s:version>2</s:version><s:shortVersionString>0.2.0</s:shortVersionString><enclosure url="https://example.invalid/AgentMetrics-2.dmg" length="42" s:edSignature="synthetic-ed25519-signature" /></item>
        </channel></rss>
        """

        #expect(throws: AppcastReleaseContractError.nonStableChannel) {
            try AppcastReleaseContract.validateFeed(xml, currentBuild: 1)
        }
    }

    @Test func rejectsSparklePrefixesBoundToAnUnofficialNamespace() {
        let xml = """
        <rss xmlns:sparkle="https://example.invalid/not-sparkle"><channel><item>
        <sparkle:version>2</sparkle:version>
        <enclosure url="https://example.invalid/AgentMetrics-2.dmg" length="42" sparkle:edSignature="synthetic-ed25519-signature" />
        </item></channel></rss>
        """

        #expect(throws: AppcastReleaseContractError.missingVersion) {
            try AppcastReleaseContract.validate(xml, currentBuild: 1)
        }
    }

    @Test(arguments: [
        ("missing EdDSA signature", appcastXML(version: "2", enclosureURL: "https://example.invalid/update.dmg", length: "42", edSignature: nil), AppcastReleaseContractError.missingEdDSASignature),
        ("zero length", appcastXML(version: "2", enclosureURL: "https://example.invalid/update.dmg", length: "0", edSignature: "synthetic"), AppcastReleaseContractError.invalidArchiveLength),
        ("non-numeric length", appcastXML(version: "2", enclosureURL: "https://example.invalid/update.dmg", length: "not-a-number", edSignature: "synthetic"), AppcastReleaseContractError.invalidArchiveLength),
        ("insecure enclosure", appcastXML(version: "2", enclosureURL: "http://example.invalid/update.dmg", length: "42", edSignature: "synthetic"), AppcastReleaseContractError.insecureEnclosureURL),
        ("beta channel", appcastXML(version: "2", enclosureURL: "https://example.invalid/update.dmg", length: "42", edSignature: "synthetic", channel: "beta"), AppcastReleaseContractError.nonStableChannel),
        ("version rollback", appcastXML(version: "1", enclosureURL: "https://example.invalid/update.dmg", length: "42", edSignature: "synthetic"), AppcastReleaseContractError.versionRollback),
    ])
    func rejectsUnsafeReleaseContract(
        _ description: String,
        xml: String,
        expectedError: AppcastReleaseContractError
    ) {
        #expect(throws: expectedError) {
            try AppcastReleaseContract.validate(xml, currentBuild: 1)
        }
    }

    @Test func rejectsAFeedWithoutExactlyOneReleaseItem() {
        #expect(throws: AppcastReleaseContractError.invalidAppcast) {
            try AppcastReleaseContract.validate(
                "<rss><channel><sparkle:version xmlns:sparkle=\"https://sparkle.example.invalid/xml-namespaces/sparkle\">2</sparkle:version></channel></rss>",
                currentBuild: 1
            )
        }
    }

    @Test func rejectsDuplicateReleaseMetadata() {
        let xml = Self.appcastXML(
            version: "2",
            enclosureURL: "https://example.invalid/update.dmg",
            length: "42",
            edSignature: "synthetic"
        ).replacingOccurrences(
            of: "<sparkle:version>2</sparkle:version>",
            with: "<sparkle:version>2</sparkle:version><sparkle:version>3</sparkle:version>"
        )

        #expect(throws: AppcastReleaseContractError.invalidAppcast) {
            try AppcastReleaseContract.validate(xml, currentBuild: 1)
        }
    }

    @Test func bundledUpdaterConfigurationUsesTheStableFeedWithoutSilentInstallation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("Sources/CodingAgentMetricsApp/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL),
            format: nil
        ) as? [String: Any]

        #expect(plist?["SUFeedURL"] as? String == "https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml")
        #expect(plist?["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(plist?["SUAutomaticallyUpdate"] as? Bool == false)
    }

    private static func appcastXML(
        version: String,
        enclosureURL: String,
        length: String,
        edSignature: String?,
        channel: String? = nil
    ) -> String {
        let signature = edSignature.map { "sparkle:edSignature=\"\($0)\"" } ?? ""
        let channelElement = channel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? ""
        return """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>\(version)</sparkle:version>\(channelElement)
        <enclosure url="\(enclosureURL)" length="\(length)" \(signature) />
        </item></channel></rss>
        """
    }

    private static func itemXML(
        version: String,
        shortVersion: String,
        enclosureURL: String? = nil,
        length: String = "42",
        edSignature: String = "synthetic-ed25519-signature"
    ) -> String {
        """
        <item><sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString><enclosure url="\(enclosureURL ?? "https://example.invalid/AgentMetrics-\(version).dmg")" length="\(length)" sparkle:edSignature="\(edSignature)" /></item>
        """
    }

    private static func appcastFeedXML(_ items: [String]) -> String {
        "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(items.joined())</channel></rss>"
    }
}

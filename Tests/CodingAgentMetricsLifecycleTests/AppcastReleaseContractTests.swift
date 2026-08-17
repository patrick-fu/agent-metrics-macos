import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

struct AppcastReleaseContractTests {
    @Test func acceptsAStableHTTPSAppcastWithEdDSASigning() throws {
        let release = try AppcastReleaseContract.validate(
            Self.appcastXML(
                version: "2",
                enclosureURL: "https://example.invalid/CodingAgentMetrics-2.dmg",
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
                "<rss><channel><sparkle:version xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">2</sparkle:version></channel></rss>",
                currentBuild: 1
            )
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
}

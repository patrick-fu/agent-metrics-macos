import Foundation

public enum ArchiveSigning: Equatable, Sendable {
    case sparkleEdDSA
}

public enum CodeSigning: Equatable, Sendable {
    /// Apple Developer ID code signing verifies the app; it is distinct from archive EdDSA signing.
    case developerIDRequired
}

public struct ValidatedAppcastRelease: Equatable, Sendable {
    public let version: Int
    public let shortVersion: String?
    public let minimumSystemVersion: String?
    public let archiveURL: URL
    public let archiveLength: UInt64
    let edSignature: String
    public let archiveSigning: ArchiveSigning
    public let codeSigning: CodeSigning
}

public enum AppcastReleaseContractError: Error, Equatable, Sendable {
    case invalidAppcast
    case missingVersion
    case invalidVersion
    case versionRollback
    case missingEdDSASignature
    case invalidArchiveLength
    case insecureEnclosureURL
    case nonStableChannel
    case nonIncreasingBuilds
}

/// Pure release-contract validation for synthetic appcasts. It validates metadata only and never
/// downloads an archive, verifies a signature, or uses signing material.
public enum AppcastReleaseContract {
    public static func validate(
        _ appcastXML: String,
        currentBuild: Int
    ) throws -> ValidatedAppcastRelease {
        let parser = AppcastParser()
        guard parser.parse(appcastXML) else {
            throw parser.contractError ?? .invalidAppcast
        }
        guard parser.itemCount == 1, parser.completedItem else {
            throw AppcastReleaseContractError.invalidAppcast
        }
        guard let versionText = parser.version else {
            throw AppcastReleaseContractError.missingVersion
        }
        guard let version = Int(versionText), version > 0 else {
            throw AppcastReleaseContractError.invalidVersion
        }
        guard version > currentBuild else {
            throw AppcastReleaseContractError.versionRollback
        }
        guard parser.channel == nil else {
            throw AppcastReleaseContractError.nonStableChannel
        }
        guard let enclosureURL = parser.enclosureURL,
              enclosureURL.scheme?.lowercased() == "https",
              enclosureURL.host != nil else {
            throw AppcastReleaseContractError.insecureEnclosureURL
        }
        guard let archiveLength = parser.archiveLength, archiveLength > 0 else {
            throw AppcastReleaseContractError.invalidArchiveLength
        }
        guard let edSignature = parser.edSignature,
              !edSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppcastReleaseContractError.missingEdDSASignature
        }
        return ValidatedAppcastRelease(
            version: version,
            shortVersion: parser.shortVersion,
            minimumSystemVersion: parser.minimumSystemVersion,
            archiveURL: enclosureURL,
            archiveLength: archiveLength,
            edSignature: edSignature,
            archiveSigning: .sparkleEdDSA,
            codeSigning: .developerIDRequired
        )
    }

    /// Validates a stable Sparkle feed and returns its highest-build release. Items must be in
    /// strictly descending build order; historical builds are permitted beneath the newest item.
    public static func validateFeed(
        _ appcastXML: String,
        currentBuild: Int
    ) throws -> ValidatedAppcastRelease {
        let parser = AppcastFeedParser()
        guard parser.parse(appcastXML), !parser.items.isEmpty else {
            throw parser.contractError ?? .invalidAppcast
        }

        let releases = try parser.items.map(validatedRelease)
        guard releases[0].version > currentBuild else {
            throw AppcastReleaseContractError.versionRollback
        }
        guard zip(releases, releases.dropFirst()).allSatisfy({ earlier, later in
            earlier.version > later.version
        }) else {
            throw AppcastReleaseContractError.nonIncreasingBuilds
        }
        return releases[0]
    }

    private static func validatedRelease(
        _ item: ParsedAppcastItem
    ) throws -> ValidatedAppcastRelease {
        guard let versionText = item.version else {
            throw AppcastReleaseContractError.missingVersion
        }
        guard let version = Int(versionText), version > 0 else {
            throw AppcastReleaseContractError.invalidVersion
        }
        guard item.channel == nil else {
            throw AppcastReleaseContractError.nonStableChannel
        }
        guard let enclosureURL = item.enclosureURL,
              enclosureURL.scheme?.lowercased() == "https",
              enclosureURL.host != nil else {
            throw AppcastReleaseContractError.insecureEnclosureURL
        }
        guard let archiveLength = item.archiveLength, archiveLength > 0 else {
            throw AppcastReleaseContractError.invalidArchiveLength
        }
        guard let edSignature = item.edSignature,
              !edSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppcastReleaseContractError.missingEdDSASignature
        }
        return ValidatedAppcastRelease(
            version: version,
            shortVersion: item.shortVersion,
            minimumSystemVersion: item.minimumSystemVersion,
            archiveURL: enclosureURL,
            archiveLength: archiveLength,
            edSignature: edSignature,
            archiveSigning: .sparkleEdDSA,
            codeSigning: .developerIDRequired
        )
    }
}

private struct ParsedAppcastItem: Sendable {
    var version: String?
    var shortVersion: String?
    var minimumSystemVersion: String?
    var channel: String?
    var enclosureURL: URL?
    var archiveLength: UInt64?
    var edSignature: String?
    var hasEnclosure = false
}

private let sparkleNamespaceURI = "http://www.andymatuschak.org/xml-namespaces/sparkle"

private enum SparkleAttribute {
    case missing
    case value(String)
    case conflicting
}

private final class XMLNamespaceContext {
    private var mappings: [String: [String]] = [:]

    func startMapping(prefix: String, uri: String) {
        mappings[prefix, default: []].append(uri)
    }

    func endMapping(prefix: String) {
        guard var values = mappings[prefix] else { return }
        values.removeLast()
        mappings[prefix] = values.isEmpty ? nil : values
    }

    func sparkleAttribute(named expectedLocalName: String, in attributes: [String: String]) -> SparkleAttribute {
        let matchingValues = attributes.compactMap { qualifiedName, value -> String? in
            let components = qualifiedName.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2,
                  String(components[1]) == expectedLocalName,
                  mappings[String(components[0])]?.last == sparkleNamespaceURI else {
                return nil
            }
            return value
        }
        switch matchingValues.count {
        case 0: return .missing
        case 1: return .value(matchingValues[0])
        default: return .conflicting
        }
    }
}

private func isSparkleMetadata(_ localName: String, namespaceURI: String?) -> Bool {
    namespaceURI == sparkleNamespaceURI && ["version", "shortVersionString", "minimumSystemVersion", "channel"].contains(localName)
}

private func isUnnamespaced(_ namespaceURI: String?) -> Bool {
    namespaceURI == nil || namespaceURI?.isEmpty == true
}

private final class AppcastFeedParser: NSObject, XMLParserDelegate {
    private(set) var items: [ParsedAppcastItem] = []
    private(set) var contractError: AppcastReleaseContractError?
    private var currentItem: ParsedAppcastItem?
    private var activeMetadataName: String?
    private var activeText = ""
    private var seenMetadataElements: Set<String> = []
    private let namespaces = XMLNamespaceContext()

    func parse(_ xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces.startMapping(prefix: prefix, uri: namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        namespaces.endMapping(prefix: prefix)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "item", isUnnamespaced(namespaceURI) {
            guard currentItem == nil else {
                fail(parser)
                return
            }
            currentItem = ParsedAppcastItem()
            seenMetadataElements = []
            return
        }
        guard var item = currentItem else { return }
        if elementName == "enclosure", isUnnamespaced(namespaceURI) {
            guard !item.hasEnclosure else {
                fail(parser)
                return
            }
            item.hasEnclosure = true
            item.enclosureURL = attributeDict["url"].flatMap(URL.init(string:))
            item.archiveLength = attributeDict["length"].flatMap(UInt64.init)
            switch namespaces.sparkleAttribute(named: "edSignature", in: attributeDict) {
            case .missing:
                break
            case let .value(signature):
                item.edSignature = signature
            case .conflicting:
                fail(parser)
                return
            }
            currentItem = item
        } else if isSparkleMetadata(elementName, namespaceURI: namespaceURI) {
            guard seenMetadataElements.insert(elementName).inserted else {
                fail(parser)
                return
            }
            activeMetadataName = elementName
            activeText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeMetadataName != nil {
            activeText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "item", isUnnamespaced(namespaceURI), let item = currentItem {
            items.append(item)
            currentItem = nil
            activeMetadataName = nil
            return
        }
        guard var item = currentItem,
              activeMetadataName == elementName,
              isSparkleMetadata(elementName, namespaceURI: namespaceURI) else { return }
        let value = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "version": item.version = value
        case "shortVersionString": item.shortVersion = value
        case "minimumSystemVersion": item.minimumSystemVersion = value
        case "channel": item.channel = value.isEmpty ? nil : value
        default: break
        }
        currentItem = item
        activeMetadataName = nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if contractError == nil { contractError = .invalidAppcast }
    }

    private func fail(_ parser: XMLParser) {
        contractError = .invalidAppcast
        parser.abortParsing()
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    private(set) var version: String?
    private(set) var shortVersion: String?
    private(set) var minimumSystemVersion: String?
    private(set) var channel: String?
    private(set) var enclosureURL: URL?
    private(set) var archiveLength: UInt64?
    private(set) var edSignature: String?
    private(set) var contractError: AppcastReleaseContractError?
    private(set) var itemCount = 0
    private(set) var completedItem = false
    private var activeMetadataName: String?
    private var activeText = ""
    private var insideItem = false
    private var seenMetadataElements: Set<String> = []
    private let namespaces = XMLNamespaceContext()

    func parse(_ xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces.startMapping(prefix: prefix, uri: namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        namespaces.endMapping(prefix: prefix)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "item", isUnnamespaced(namespaceURI) {
            itemCount += 1
            guard itemCount == 1 else {
                fail(parser)
                return
            }
            insideItem = true
            return
        }
        guard insideItem else { return }
        if elementName == "enclosure", isUnnamespaced(namespaceURI) {
            guard enclosureURL == nil else {
                fail(parser)
                return
            }
            enclosureURL = attributeDict["url"].flatMap(URL.init(string:))
            archiveLength = attributeDict["length"].flatMap(UInt64.init)
            switch namespaces.sparkleAttribute(named: "edSignature", in: attributeDict) {
            case .missing:
                break
            case let .value(signature):
                edSignature = signature
            case .conflicting:
                fail(parser)
                return
            }
        } else if isSparkleMetadata(elementName, namespaceURI: namespaceURI) {
            guard seenMetadataElements.insert(elementName).inserted else {
                fail(parser)
                return
            }
            activeMetadataName = elementName
            activeText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeMetadataName != nil {
            activeText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "item", isUnnamespaced(namespaceURI), insideItem {
            completedItem = true
            insideItem = false
            activeMetadataName = nil
            return
        }
        guard insideItem,
              activeMetadataName == elementName,
              isSparkleMetadata(elementName, namespaceURI: namespaceURI) else { return }
        let value = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "version": version = value
        case "shortVersionString": shortVersion = value
        case "minimumSystemVersion": minimumSystemVersion = value
        case "channel": channel = value.isEmpty ? nil : value
        default: break
        }
        activeMetadataName = nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if contractError == nil { contractError = .invalidAppcast }
    }

    private func fail(_ parser: XMLParser) {
        contractError = .invalidAppcast
        parser.abortParsing()
    }
}

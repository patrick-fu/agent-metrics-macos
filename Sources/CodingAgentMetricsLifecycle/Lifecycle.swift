import Foundation
import Observation
import ServiceManagement
import Sparkle

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LaunchAtLoginService: AnyObject {
    func registrationStatus() -> LaunchAtLoginStatus
    func register() throws
    func unregister() throws
}

@MainActor
public final class SystemLaunchAtLoginService: LaunchAtLoginService {
    public init() {}

    public func registrationStatus() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
@Observable
public final class LaunchAtLoginController {
    public private(set) var status: LaunchAtLoginStatus
    public private(set) var failureMessage: String?

    @ObservationIgnored private let service: any LaunchAtLoginService

    public init(service: any LaunchAtLoginService) {
        self.service = service
        self.status = service.registrationStatus()
        self.failureMessage = nil
    }

    public var isEnabled: Bool {
        status == .enabled
    }

    public var statusMessage: String {
        switch status {
        case .notRegistered:
            "Off"
        case .enabled:
            "On"
        case .requiresApproval:
            "Approval is required in Login Items settings."
        case .unavailable:
            "Launch at Login is unavailable."
        }
    }

    public func refresh() {
        status = service.registrationStatus()
    }

    public func setEnabled(_ enabled: Bool) {
        failureMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failureMessage = "Unable to change Launch at Login: \(error.localizedDescription)"
        }
        refresh()
    }
}

@MainActor
public protocol UpdateCheckingService: AnyObject {
    func checkForUpdates()
}

@MainActor
public final class SparkleUpdateService: UpdateCheckingService {
    private let updaterController: SPUStandardUpdaterController

    public init() {
        updaterController = SPUStandardUpdaterController(
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    public func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

@MainActor
@Observable
public final class UpdateCheckController {
    @ObservationIgnored private let service: any UpdateCheckingService

    public init(service: any UpdateCheckingService) {
        self.service = service
    }

    public func checkForUpdates() {
        service.checkForUpdates()
    }
}

@MainActor
public struct AppLifecycleServices {
    public let launchAtLogin: LaunchAtLoginController
    public let updates: UpdateCheckController

    public init(
        launchAtLogin: LaunchAtLoginController,
        updates: UpdateCheckController
    ) {
        self.launchAtLogin = launchAtLogin
        self.updates = updates
    }

    public static let live = AppLifecycleServices(
        launchAtLogin: LaunchAtLoginController(service: SystemLaunchAtLoginService()),
        updates: UpdateCheckController(service: SparkleUpdateService())
    )
}

public enum ArchiveSigning: Equatable, Sendable {
    case sparkleEdDSA
}

public enum CodeSigning: Equatable, Sendable {
    /// Apple Developer ID code signing verifies the app; it is distinct from archive EdDSA signing.
    case developerIDRequired
}

public struct ValidatedAppcastRelease: Equatable, Sendable {
    public let version: Int
    public let archiveURL: URL
    public let archiveLength: UInt64
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
            archiveURL: enclosureURL,
            archiveLength: archiveLength,
            archiveSigning: .sparkleEdDSA,
            codeSigning: .developerIDRequired
        )
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    private(set) var version: String?
    private(set) var channel: String?
    private(set) var enclosureURL: URL?
    private(set) var archiveLength: UInt64?
    private(set) var edSignature: String?
    private(set) var contractError: AppcastReleaseContractError?
    private(set) var itemCount = 0
    private(set) var completedItem = false
    private var activeElement: String?
    private var activeText = ""
    private var insideItem = false

    func parse(_ xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let qualifiedName = qName ?? elementName
        let localName = Self.localName(qualifiedName)
        if localName == "item", !qualifiedName.contains(":") {
            itemCount += 1
            guard itemCount == 1 else {
                contractError = .invalidAppcast
                parser.abortParsing()
                return
            }
            insideItem = true
            return
        }
        guard insideItem else { return }
        switch localName {
        case "enclosure":
            guard enclosureURL == nil else {
                contractError = .invalidAppcast
                parser.abortParsing()
                return
            }
            enclosureURL = attributeDict["url"].flatMap(URL.init(string:))
            archiveLength = attributeDict["length"].flatMap(UInt64.init)
            edSignature = attributeDict["sparkle:edSignature"] ?? attributeDict["edSignature"]
        case "version" where qualifiedName.hasPrefix("sparkle:"),
             "channel" where qualifiedName.hasPrefix("sparkle:"):
            activeElement = localName
            activeText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        activeText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let qualifiedName = qName ?? elementName
        let localName = Self.localName(qualifiedName)
        if localName == "item", !qualifiedName.contains(":"), insideItem {
            completedItem = true
            insideItem = false
            activeElement = nil
            return
        }
        guard insideItem else { return }
        guard activeElement == localName else { return }
        let value = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName {
        case "version":
            if version == nil { version = value }
        case "channel":
            channel = value.isEmpty ? nil : value
        default:
            break
        }
        activeElement = nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if contractError == nil { contractError = .invalidAppcast }
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

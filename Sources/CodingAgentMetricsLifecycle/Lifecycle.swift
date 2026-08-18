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

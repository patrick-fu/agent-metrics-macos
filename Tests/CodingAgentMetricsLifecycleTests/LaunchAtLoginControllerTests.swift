import Foundation
import Testing
@testable import CodingAgentMetricsLifecycle

@MainActor
struct LaunchAtLoginControllerTests {
    @Test func enablingRegistersTheMainApplicationAndRefreshesTheReportedState() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCalls == 1)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.failureMessage == nil)
    }

    @Test func disablingReportsTheServiceFailureAndKeepsTheActualRegistrationState() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = FakeError.denied
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        #expect(service.unregisterCalls == 1)
        #expect(controller.status == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.failureMessage == "Unable to change Launch at Login: The system denied this change.")
    }

    @Test func approvalRequiredIsNotReportedAsEnabled() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        #expect(controller.status == .requiresApproval)
        #expect(!controller.isEnabled)
        #expect(controller.statusMessage == "Approval is required in Login Items settings.")
    }

    @Test func manualUpdateCheckDelegatesToTheInjectedUpdateService() {
        let service = FakeUpdateCheckingService()
        let controller = UpdateCheckController(service: service)

        controller.checkForUpdates()

        #expect(service.checkCalls == 1)
    }

    private final class FakeLaunchAtLoginService: LaunchAtLoginService {
        var status: LaunchAtLoginStatus
        var registerCalls = 0
        var unregisterCalls = 0
        var registerError: Error?
        var unregisterError: Error?

        init(status: LaunchAtLoginStatus) {
            self.status = status
        }

        func registrationStatus() -> LaunchAtLoginStatus {
            status
        }

        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    private enum FakeError: LocalizedError {
        case denied

        var errorDescription: String? {
            "The system denied this change."
        }
    }

    private final class FakeUpdateCheckingService: UpdateCheckingService {
        var checkCalls = 0

        func checkForUpdates() {
            checkCalls += 1
        }
    }
}

import CodingAgentMetricsLifecycle

@MainActor
func inertLifecycleServices() -> AppLifecycleServices {
    AppLifecycleServices(
        launchAtLogin: LaunchAtLoginController(service: InertLaunchAtLoginService()),
        updates: UpdateCheckController(service: InertUpdateCheckingService())
    )
}

@MainActor
private final class InertLaunchAtLoginService: LaunchAtLoginService {
    func registrationStatus() -> LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class InertUpdateCheckingService: UpdateCheckingService {
    func checkForUpdates() {}
}

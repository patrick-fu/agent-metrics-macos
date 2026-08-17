import Foundation

public enum CodexHome {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = environment["CODEX_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

extension FixtureLocator {
    public static var codexHomeV1: URL {
        syntheticCodexTokenCountV1
            .deletingLastPathComponent()
            .appendingPathComponent("codex-home-v1", isDirectory: true)
    }

    public static var codexHomeV1Rollout: URL {
        codexHomeV1
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("04", isDirectory: true)
            .appendingPathComponent("15", isDirectory: true)
            .appendingPathComponent(
                "rollout-2026-04-15T12-00-00-01900000-0000-7000-8000-000000000013.jsonl"
            )
    }
}

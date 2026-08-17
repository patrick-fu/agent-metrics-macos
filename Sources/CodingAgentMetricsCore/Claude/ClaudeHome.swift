import Foundation

public enum ClaudeHome {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }
}

import Foundation
import Testing

struct PagesBuildOutputSafetyTests {
    @Test func buildRejectsASymlinkOutputBeforeWritingToItsEmptyExternalTarget() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let externalTarget = temporaryDirectory.appendingPathComponent("external-target", isDirectory: true)
        let outputLink = temporaryDirectory.appendingPathComponent("output-link")
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: outputLink.path,
            withDestinationPath: externalTarget.path
        )

        let result = try Self.runBuild(output: outputLink)

        #expect(result.status != 0)
        #expect(result.output.contains("output directory must not be a symlink"), Comment(rawValue: result.output))
        #expect(try FileManager.default.contentsOfDirectory(atPath: externalTarget.path).isEmpty)
    }

    @Test func buildAcceptsAnAbsentOutputDirectory() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let output = temporaryDirectory.appendingPathComponent("absent-output", isDirectory: true)

        let result = try Self.runBuild(output: output)

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
    }

    @Test func buildAcceptsARealEmptyOutputDirectory() throws {
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let output = temporaryDirectory.appendingPathComponent("empty-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let result = try Self.runBuild(output: output)

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-metrics-pages-output-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func runBuild(output: URL) throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("scripts/build-site.sh").path, output.path]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

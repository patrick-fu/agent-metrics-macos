import Foundation

/// Incrementally reads only the allowlisted Claude Code transcript usage shapes.
/// Transcript text, working directories, credentials, and unfinished tails are never retained.
public struct ClaudeTranscriptSourceAdapter: IncrementalSourceAdapter {
    public var home: URL
    private static let maximumDirectoryEntries = 4_096
    private static let maximumTranscriptFiles = 256
    private static let maximumDirectoryDepth = 12

    public init(home: URL) {
        self.home = home
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(home: ClaudeHome.resolve(environment: environment))
    }

    public var sourceID: String { ClaudeTranscriptParser.sourceID }

    public var sourceRebuildScope: SourceFactScope {
        .schemaVersion(ClaudeTranscriptParser.schemaVersion)
    }

    public func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("claude-transcript:\(identity):")
    }

    public func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        try scan(clock: clock, state: nil).observations
    }

    public func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        if let state, state.parserVersion != ClaudeTranscriptParser.semanticVersion {
            let rebuilt = try scanPass(clock: clock, state: nil, forceRebuild: true)
            let diagnostic = SourceDiagnostic(code: "PARSER_VERSION_CHANGED", sourceID: sourceID)
            return SourceScan(
                observations: rebuilt.observations,
                state: rebuilt.state,
                rebuildSource: true,
                rebuiltFileIdentities: rebuilt.rebuiltFileIdentities,
                diagnostics: [diagnostic] + rebuilt.diagnostics,
                health: SourceHealth(sourceID: sourceID, isHealthy: false, diagnosticCode: diagnostic.code)
            )
        }

        let first = try scanPass(clock: clock, state: state, forceRebuild: false)
        if first.rebuildSource {
            let rebuilt = try scanPass(clock: clock, state: nil, forceRebuild: true)
            return SourceScan(
                observations: rebuilt.observations,
                state: rebuilt.state,
                rebuildSource: true,
                rebuiltFileIdentities: rebuilt.rebuiltFileIdentities,
                diagnostics: rebuilt.diagnostics,
                health: rebuilt.health
            )
        }
        return first
    }

    private func scanPass(
        clock: any Clock,
        state: SourceState?,
        forceRebuild: Bool
    ) throws -> SourceScan {
        var working = state ?? SourceState(
            sourceID: sourceID,
            parserVersion: ClaudeTranscriptParser.semanticVersion
        )
        working.sourceID = sourceID
        working.parserVersion = ClaudeTranscriptParser.semanticVersion

        let files = try discoverTranscripts()
        let missingKnownFiles = !Set(working.files.keys).subtracting(files.map(\.identity)).isEmpty
        if files.isEmpty, !working.files.isEmpty {
            return SourceScan(
                observations: [],
                state: working,
                rebuildSource: false,
                diagnostics: working.diagnosticCodes.map { SourceDiagnostic(code: $0, sourceID: sourceID) },
                health: SourceHealth(sourceID: sourceID, isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE")
            )
        }

        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = forceRebuild
            ? []
            : working.diagnosticCodes.map { SourceDiagnostic(code: $0, sourceID: sourceID) }
        var rebuiltFileIdentities: [String] = []
        var seen = Set<String>()

        for file in files {
            let result = try scanFile(file, clock: clock, state: &working, forceRebuild: forceRebuild)
            if result.rollback {
                return SourceScan(
                    observations: [],
                    state: working,
                    rebuildSource: true,
                    health: SourceHealth(sourceID: sourceID, isHealthy: true)
                )
            }
            if result.requiresSourceRebuild {
                return SourceScan(
                    observations: [],
                    state: working,
                    rebuildSource: true,
                    health: SourceHealth(sourceID: sourceID, isHealthy: true)
                )
            }
            if result.rebuiltFile, !forceRebuild, !working.diagnosticCodes.isEmpty {
                return SourceScan(
                    observations: [],
                    state: working,
                    rebuildSource: true,
                    health: SourceHealth(sourceID: sourceID, isHealthy: true)
                )
            }
            if result.rebuiltFile { rebuiltFileIdentities.append(file.identity) }
            diagnostics.append(contentsOf: result.diagnostics)
            for observation in result.observations where seen.insert(observation.observationIdentity).inserted {
                observations.append(observation)
            }
        }

        let uniqueDiagnostics = diagnostics.reduce(into: [SourceDiagnostic]()) { collected, diagnostic in
            if !collected.contains(diagnostic) { collected.append(diagnostic) }
        }
        working.diagnosticCodes = uniqueDiagnostics.map(\.code)
        return SourceScan(
            observations: observations,
            state: working,
            rebuildSource: false,
            rebuiltFileIdentities: rebuiltFileIdentities,
            diagnostics: uniqueDiagnostics,
            health: SourceHealth(
                sourceID: sourceID,
                isHealthy: !missingKnownFiles && uniqueDiagnostics.isEmpty,
                diagnosticCode: missingKnownFiles ? "SOURCE_UNAVAILABLE" : uniqueDiagnostics.first?.code
            )
        )
    }

    private func scanFile(
        _ file: DiscoveredClaudeTranscript,
        clock: any Clock,
        state: inout SourceState,
        forceRebuild: Bool
    ) throws -> ClaudeFileScanResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let generation = "\(inode)"
        let prior = forceRebuild ? nil : state.files[file.identity]
        var startOffset = prior?.offset ?? 0
        var rebuiltFile = forceRebuild || prior == nil

        if let prior {
            if prior.generation != generation || prior.offset > size {
                startOffset = 0
                rebuiltFile = true
            } else if prior.offset > 0 {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                let prefix = try handle.read(upToCount: Int(prior.offset)) ?? Data()
                if ClaudeTranscriptParser.fingerprint(prefix) != prior.prefixFingerprint {
                    startOffset = 0
                    rebuiltFile = true
                }
            }
        }
        if rebuiltFile {
            startOffset = 0
            clearWatermarks(for: file.identity, state: &state)
        }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        let appended = try handle.readToEnd() ?? Data()
        let lines = completeLines(in: appended)
        let newOffset = startOffset + lines.consumed
        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = []
        var rollback = false
        var requiresSourceRebuild = false
        var authoritativeSessions = Set(state.messageTotalSessions)
        for line in lines.lines {
            if let value = line.value,
               case let .messageTotal(_, sessionID, _, _, _) = ClaudeTranscriptParser.parseLine(value) {
                authoritativeSessions.insert(sessionID)
            }
        }

        for line in lines.lines {
            let endOffset = startOffset + line.endOffset
            guard let value = line.value else {
                diagnostics.append(SourceDiagnostic(code: "UNKNOWN_SCHEMA", sourceID: sourceID))
                continue
            }
            switch ClaudeTranscriptParser.parseLine(value) {
            case .ignored:
                continue
            case .unknownSchema:
                diagnostics.append(SourceDiagnostic(code: "UNKNOWN_SCHEMA", sourceID: sourceID))
            case let .messageTotal(identity, sessionID, model, total, timestamp):
                if !forceRebuild && state.sessionFallbackSessions.contains(sessionID) {
                    requiresSourceRebuild = true
                    break
                }
                state.messageTotalSessions = Array(Set(state.messageTotalSessions).union([sessionID])).sorted()
                let key = "\(file.identity):message:\(identity)"
                let watermark = state.watermarks[key] ?? 0
                if total < watermark {
                    if forceRebuild {
                        observations.removeAll { $0.turnID == identity }
                        appendObservation(
                            &observations,
                            fileIdentity: file.identity,
                            lineEndOffset: endOffset,
                            sessionID: sessionID,
                            turnID: identity,
                            model: ModelIdentity(raw: model, display: model),
                            outputTokens: total,
                            timestamp: timestamp,
                            clock: clock
                        )
                        state.watermarks[key] = total
                    } else {
                        rollback = true
                    }
                } else if total > watermark {
                    appendObservation(
                        &observations,
                        fileIdentity: file.identity,
                        lineEndOffset: endOffset,
                        sessionID: sessionID,
                        turnID: identity,
                        model: ModelIdentity(raw: model, display: model),
                        outputTokens: total - watermark,
                        timestamp: timestamp,
                        clock: clock
                    )
                    state.watermarks[key] = total
                }
            case let .sessionTotal(sessionID, total, timestamp):
                guard !authoritativeSessions.contains(sessionID) else { continue }
                state.sessionFallbackSessions = Array(Set(state.sessionFallbackSessions).union([sessionID])).sorted()
                let key = "\(file.identity):session:\(sessionID)"
                let watermark = state.watermarks[key] ?? 0
                if total < watermark {
                    if forceRebuild {
                        observations.removeAll { $0.sessionID == sessionID && $0.model.raw == "unknown" }
                        appendObservation(
                            &observations,
                            fileIdentity: file.identity,
                            lineEndOffset: endOffset,
                            sessionID: sessionID,
                            turnID: sessionID,
                            model: ModelIdentity(raw: "unknown", display: "unknown"),
                            outputTokens: total,
                            timestamp: timestamp,
                            clock: clock
                        )
                        state.watermarks[key] = total
                    } else {
                        rollback = true
                    }
                } else if total > watermark {
                    appendObservation(
                        &observations,
                        fileIdentity: file.identity,
                        lineEndOffset: endOffset,
                        sessionID: sessionID,
                        turnID: sessionID,
                        model: ModelIdentity(raw: "unknown", display: "unknown"),
                        outputTokens: total - watermark,
                        timestamp: timestamp,
                        clock: clock
                    )
                    state.watermarks[key] = total
                }
            }
            if rollback || requiresSourceRebuild { break }
        }

        let prefixHandle = try FileHandle(forReadingFrom: file.url)
        defer { try? prefixHandle.close() }
        let prefix = try prefixHandle.read(upToCount: Int(newOffset)) ?? Data()
        state.files[file.identity] = SourceFileCursor(
            fileIdentity: file.identity,
            locator: file.locator,
            generation: generation,
            prefixFingerprint: ClaudeTranscriptParser.fingerprint(prefix),
            offset: newOffset,
            parserVersion: ClaudeTranscriptParser.semanticVersion
        )
        return ClaudeFileScanResult(
            observations: observations,
            diagnostics: diagnostics,
            rebuiltFile: rebuiltFile,
            rollback: rollback,
            requiresSourceRebuild: requiresSourceRebuild
        )
    }

    private func appendObservation(
        _ observations: inout [UsageObservation],
        fileIdentity: String,
        lineEndOffset: Int64,
        sessionID: String,
        turnID: String,
        model: ModelIdentity,
        outputTokens: Int,
        timestamp: String?,
        clock: any Clock
    ) {
        guard outputTokens > 0 else { return }
        observations.append(UsageObservation(
            observationIdentity: "claude-transcript:\(fileIdentity):\(lineEndOffset)",
            schemaVersion: ClaudeTranscriptParser.schemaVersion,
            codingAgent: .claudeCode,
            model: model,
            sessionID: sessionID,
            turnID: turnID,
            observedAt: ClaudeTranscriptParser.parseTimestamp(timestamp)!,
            outputTokens: outputTokens
        ))
    }

    private func clearWatermarks(for identity: String, state: inout SourceState) {
        state.watermarks = state.watermarks.filter { key, _ in !key.hasPrefix("\(identity):") }
    }

    private func completeLines(in data: Data) -> (lines: [(value: String?, endOffset: Int64)], consumed: Int64) {
        var lines: [(value: String?, endOffset: Int64)] = []
        var start = data.startIndex
        var consumed = 0
        while let newline = data[start...].firstIndex(of: 10) {
            let lineData = data[start..<newline]
            let next = data.index(after: newline)
            consumed += data.distance(from: start, to: next)
            let line = String(data: Data(lineData), encoding: .utf8)
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed?.isEmpty == false || line == nil { lines.append((trimmed, Int64(consumed))) }
            start = next
        }
        return (lines, Int64(consumed))
    }

    private func discoverTranscripts() throws -> [DiscoveredClaudeTranscript] {
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else { return [] }
        let resolvedProjects = projects.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var discovered: [String: DiscoveredClaudeTranscript] = [:]
        var entryCount = 0
        for case let url as URL in enumerator {
            entryCount += 1
            guard entryCount <= Self.maximumDirectoryEntries else {
                throw ClaudeTranscriptAdapterError.discoveryLimitExceeded
            }
            if enumerator.level > Self.maximumDirectoryDepth {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(resolvedProjects + "/") else {
                throw ClaudeTranscriptAdapterError.pathEscapesProjectsRoot
            }
            guard let identity = ClaudeTranscriptParser.fileIdentity(fromFileName: url.lastPathComponent) else { continue }
            let item = DiscoveredClaudeTranscript(
                identity: identity,
                locator: "projects/\(identity).jsonl",
                url: url
            )
            guard discovered[identity] == nil else { throw ClaudeTranscriptAdapterError.identityCollision }
            guard discovered.count < Self.maximumTranscriptFiles else {
                throw ClaudeTranscriptAdapterError.discoveryLimitExceeded
            }
            discovered[identity] = item
        }
        return discovered.values.sorted { $0.locator < $1.locator }
    }
}

private struct DiscoveredClaudeTranscript {
    var identity: String
    var locator: String
    var url: URL
}

private struct ClaudeFileScanResult {
    var observations: [UsageObservation]
    var diagnostics: [SourceDiagnostic]
    var rebuiltFile: Bool
    var rollback: Bool
    var requiresSourceRebuild: Bool
}

private enum ClaudeTranscriptAdapterError: Error {
    case discoveryLimitExceeded
    case pathEscapesProjectsRoot
    case identityCollision
}

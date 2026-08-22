import Foundation

/// Incrementally reads only the allowlisted Claude Code transcript usage shapes.
/// Transcript text, working directories, credentials, and unfinished tails are never retained.
public struct ClaudeTranscriptSourceAdapter: IncrementalSourceAdapter {
    static let maximumAppendBytesPerFile = 512 * 1_024
    public var home: URL
    private static let maximumDirectoryEntries = 4_096
    private static let maximumTranscriptFiles = 256
    private static let maximumDirectoryDepth = 12
    private static let fingerprintSampleBytes = 64 * 1_024

    public init(home: URL) {
        self.home = home
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(home: ClaudeHome.resolve(environment: environment))
    }

    public var sourceID: String { ClaudeTranscriptParser.sourceID }

    public var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.claudeCode],
            channels: [.claudeTranscript]
        )
    }

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
                health: SourceHealth.usage(sourceID: sourceID, codingAgent: .claudeCode, channel: .claudeTranscript, isHealthy: false, diagnosticCode: diagnostic.code)
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
        working.diagnosticCodes.removeAll { $0 == "SOURCE_OVERLOADED" }

        let discovery = try discoverTranscripts()
        let files = discovery.files
        let missingKnownFiles = !Set(working.files.keys).subtracting(discovery.identities).isEmpty
        if files.isEmpty, !working.files.isEmpty {
            return SourceScan(
                observations: [],
                state: working,
                rebuildSource: false,
                diagnostics: working.diagnosticCodes.map { SourceDiagnostic(code: $0, sourceID: sourceID) },
                health: SourceHealth.usage(sourceID: sourceID, codingAgent: .claudeCode, channel: .claudeTranscript, isHealthy: false, diagnosticCode: "SOURCE_UNAVAILABLE")
            )
        }

        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = forceRebuild
            ? []
            : working.diagnosticCodes.map { SourceDiagnostic(code: $0, sourceID: sourceID) }
        if discovery.isTruncated {
            diagnostics.append(SourceDiagnostic(code: "SOURCE_OVERLOADED", sourceID: sourceID))
        }
        var rebuiltFileIdentities: [String] = []
        var seen = Set<String>()

        for file in files {
            let result = try scanFile(file, clock: clock, state: &working, forceRebuild: forceRebuild)
            if result.rollback {
                return SourceScan(
                    observations: [],
                    state: working,
                    rebuildSource: true,
                    health: SourceHealth.usage(sourceID: sourceID, codingAgent: .claudeCode, channel: .claudeTranscript, isHealthy: true)
                )
            }
            if result.requiresSourceRebuild {
                return SourceScan(
                    observations: [],
                    state: working,
                    rebuildSource: true,
                    health: SourceHealth.usage(sourceID: sourceID, codingAgent: .claudeCode, channel: .claudeTranscript, isHealthy: true)
                )
            }
            if result.rebuiltFile, !forceRebuild, !working.diagnosticCodes.isEmpty {
                return SourceScan(
                    observations: [],
                    state: working,
                    rebuildSource: true,
                    health: SourceHealth.usage(sourceID: sourceID, codingAgent: .claudeCode, channel: .claudeTranscript, isHealthy: true)
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
            health: SourceHealth.usage(
                sourceID: sourceID,
                codingAgent: .claudeCode,
                channel: .claudeTranscript,
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
        let lastModifiedAt = attributes[.modificationDate] as? Date
        let prior = forceRebuild ? nil : state.files[file.identity]
        var startOffset = prior?.offset ?? 0
        var rebuiltFile = forceRebuild || prior == nil

        if let prior {
            if prior.generation != generation || prior.offset > size {
                startOffset = 0
                rebuiltFile = true
            } else if let priorSize = prior.lastObservedSize,
                      let priorModifiedAt = prior.lastModifiedAt {
                if size < priorSize || (size == priorSize && lastModifiedAt != priorModifiedAt) {
                    startOffset = 0
                    rebuiltFile = true
                }
            } else {
                startOffset = 0
                rebuiltFile = true
            }
            if !rebuiltFile, prior.offset > 0 {
                if try cursorFingerprint(file.url, upTo: prior.offset) != prior.prefixFingerprint {
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
        let appended = try handle.read(upToCount: Self.maximumAppendBytesPerFile) ?? Data()
        let lines = BoundedJSONL.completeLines(
            in: appended,
            maximumBatchBytes: Self.maximumAppendBytesPerFile,
            discardingOversizedLine: !rebuiltFile && prior?.discardingOversizedLine == true
        )
        let newOffset = startOffset + lines.consumed
        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = []
        if lines.encounteredOversizedLine {
            diagnostics.append(SourceDiagnostic(code: "SOURCE_LINE_TOO_LONG", sourceID: sourceID))
        }
        if startOffset + Int64(appended.count) < size {
            diagnostics.append(SourceDiagnostic(code: "SOURCE_OVERLOADED", sourceID: sourceID))
        }
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
            case let .messageTotal(identity, sessionID, model, usage, timestamp):
                guard let total = usage.outputTotal else { continue }
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
                            tokenParts: deltaParts(usage: usage, keyPrefix: key, state: &state, reset: true),
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
                        tokenParts: deltaParts(usage: usage, keyPrefix: key, state: &state),
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

        state.files[file.identity] = SourceFileCursor(
            fileIdentity: file.identity,
            locator: file.locator,
            generation: generation,
            prefixFingerprint: try cursorFingerprint(file.url, upTo: newOffset),
            offset: newOffset,
            parserVersion: ClaudeTranscriptParser.semanticVersion,
            lastObservedSize: size,
            lastModifiedAt: lastModifiedAt,
            discardingOversizedLine: lines.discardingOversizedLine
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
        tokenParts: TokenParts? = nil,
        timestamp: String?,
        clock: any Clock
    ) {
        guard outputTokens > 0 else { return }
        observations.append(UsageObservation(
            observationIdentity: "claude-transcript:\(fileIdentity):\(lineEndOffset)",
            schemaVersion: ClaudeTranscriptParser.schemaVersion,
            sourceID: ClaudeTranscriptParser.sourceID,
            codingAgent: .claudeCode,
            model: model,
            sessionID: sessionID,
            turnID: turnID,
            observedAt: ClaudeTranscriptParser.parseTimestamp(timestamp)!,
            outputTokens: outputTokens,
            tokenParts: tokenParts
        ))
    }

    /// Anthropic usage fields are additive/disjoint.  It does not expose a
    /// visible-vs-reasoning split, but its normalized burn total includes the
    /// whole output count exactly once.
    private func deltaParts(usage: ClaudeRawTokenUsage, keyPrefix: String, state: inout SourceState, reset: Bool = false) -> TokenParts? {
        guard let input = usage.inputUncached, let write = usage.cacheWrite,
              let read = usage.cacheRead, let output = usage.outputTotal else { return nil }
        func delta(_ value: Int, _ name: String) -> Int {
            let key = "\(keyPrefix):\(name)"
            let watermark = reset ? 0 : (state.watermarks[key] ?? 0)
            state.watermarks[key] = value
            return max(0, value - watermark)
        }
        let inputDelta = delta(input, "input")
        let writeDelta = delta(write, "write")
        let readDelta = delta(read, "read")
        let outputDelta = delta(output, "output")
        return TokenParts(
            inputUncached: inputDelta,
            cacheRead: readDelta,
            cacheWrite: writeDelta,
            outputVisible: nil,
            reasoning: nil,
            normalizedBurnTotal: inputDelta + writeDelta + readDelta + outputDelta
        )
    }

    private func clearWatermarks(for identity: String, state: inout SourceState) {
        state.watermarks = state.watermarks.filter { key, _ in !key.hasPrefix("\(identity):") }
    }

    private func discoverTranscripts() throws -> ClaudeTranscriptDiscovery {
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            return ClaudeTranscriptDiscovery(files: [], identities: [], isTruncated: false)
        }
        let resolvedProjects = projects.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ClaudeTranscriptDiscovery(files: [], identities: [], isTruncated: false)
        }
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
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(resolvedProjects + "/") else {
                throw ClaudeTranscriptAdapterError.pathEscapesProjectsRoot
            }
            guard let identity = ClaudeTranscriptParser.fileIdentity(fromFileName: url.lastPathComponent) else { continue }
            let item = DiscoveredClaudeTranscript(
                identity: identity,
                locator: "projects/\(identity).jsonl",
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
            guard discovered[identity] == nil else { throw ClaudeTranscriptAdapterError.identityCollision }
            discovered[identity] = item
        }
        let mostRecent = discovered.values.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
            return lhs.locator < rhs.locator
        }
        return ClaudeTranscriptDiscovery(
            files: Array(mostRecent.prefix(Self.maximumTranscriptFiles)).sorted { $0.locator < $1.locator },
            identities: Set(discovered.keys),
            isTruncated: discovered.count > Self.maximumTranscriptFiles
        )
    }

    private func cursorFingerprint(_ url: URL, upTo offset: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = Int64(Self.fingerprintSampleBytes)
        var data = try handle.read(upToCount: Int(min(offset, sample))) ?? Data()
        if offset > sample {
            try handle.seek(toOffset: UInt64(max(sample, offset - sample)))
            data.append(try handle.read(upToCount: Int(min(sample, offset - sample))) ?? Data())
        }
        return ClaudeTranscriptParser.fingerprint(data)
    }
}

private struct DiscoveredClaudeTranscript {
    var identity: String
    var locator: String
    var url: URL
    var modifiedAt: Date
}

private struct ClaudeTranscriptDiscovery {
    var files: [DiscoveredClaudeTranscript]
    var identities: Set<String>
    var isTruncated: Bool
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

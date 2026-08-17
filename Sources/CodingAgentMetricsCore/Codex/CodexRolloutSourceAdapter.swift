import Foundation

public struct CodexRolloutSourceAdapter: IncrementalSourceAdapter {
    public var sessionRoot: URL

    public init(sessionRoot: URL) {
        self.sessionRoot = sessionRoot
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(sessionRoot: CodexHome.resolve(environment: environment))
    }

    public var sourceID: String { CodexRolloutParser.sourceID }

    public var sourceRebuildScope: SourceFactScope {
        .schemaVersion(CodexRolloutParser.schemaVersion)
    }

    public func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("codex-rollout:\(identity):")
    }

    public func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        try scan(clock: clock, state: nil).observations
    }

    public func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        if let state, state.parserVersion != CodexRolloutParser.semanticVersion {
            let rebuilt = try scanPass(clock: clock, state: nil, forceRebuild: true)
            let parserVersionChanged = SourceDiagnostic(
                code: "PARSER_VERSION_CHANGED",
                sourceID: sourceID
            )
            return SourceScan(
                observations: rebuilt.observations,
                state: rebuilt.state,
                rebuildSource: true,
                rebuiltFileIdentities: rebuilt.rebuiltFileIdentities,
                diagnostics: [parserVersionChanged] + rebuilt.diagnostics,
                health: SourceHealth(
                    sourceID: sourceID,
                    isHealthy: false,
                    diagnosticCode: parserVersionChanged.code
                )
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
            parserVersion: CodexRolloutParser.semanticVersion
        )
        working.sourceID = sourceID
        working.parserVersion = CodexRolloutParser.semanticVersion

        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = []
        var rebuiltFileIdentities: [String] = []
        var rebuildSource = false
        var seenIdentities = Set<String>()

        let files = try discoverRollouts()
        let discoveredIdentities = Set(files.map(\.identity))
        working.files = working.files.filter { discoveredIdentities.contains($0.key) }
        working.watermarks = working.watermarks.filter { discoveredIdentities.contains($0.key) }

        for file in files {
            let result = try scanFile(
                file,
                clock: clock,
                state: &working,
                forceRebuild: forceRebuild
            )
            if result.rollback {
                rebuildSource = true
                break
            }
            if result.rebuiltFile {
                rebuiltFileIdentities.append(file.identity)
            }
            for observation in result.observations where seenIdentities.insert(observation.observationIdentity).inserted {
                observations.append(observation)
            }
            diagnostics.append(contentsOf: result.diagnostics)
        }

        let uniqueDiagnostics = diagnostics.reduce(into: [SourceDiagnostic]()) { collected, item in
            if !collected.contains(item) {
                collected.append(item)
            }
        }
        let health = SourceHealth(
            sourceID: sourceID,
            isHealthy: uniqueDiagnostics.isEmpty,
            diagnosticCode: uniqueDiagnostics.first?.code
        )
        return SourceScan(
            observations: observations,
            state: working,
            rebuildSource: rebuildSource,
            rebuiltFileIdentities: rebuiltFileIdentities,
            diagnostics: uniqueDiagnostics,
            health: health
        )
    }

    private func scanFile(
        _ file: DiscoveredRollout,
        clock: any Clock,
        state: inout SourceState,
        forceRebuild: Bool
    ) throws -> FileScanResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let generation = "\(inode)-\(size)"
        let prior = forceRebuild ? nil : state.files[file.identity]

        var startOffset: Int64 = prior?.offset ?? 0
        var rebuiltFile = forceRebuild || prior == nil
        if let prior {
            if prior.offset > size {
                startOffset = 0
                rebuiltFile = true
            } else if prior.offset > 0 {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                let prefix = try handle.read(upToCount: Int(prior.offset)) ?? Data()
                if CodexRolloutParser.fingerprint(prefix) != prior.prefixFingerprint {
                    startOffset = 0
                    rebuiltFile = true
                }
            }
        }
        if rebuiltFile {
            startOffset = 0
            state.watermarks[file.identity] = 0
        }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        let appended = try handle.readToEnd() ?? Data()
        let completeLines = completeLines(in: appended)
        let consumed = completeLines.consumed
        let newOffset = startOffset + consumed

        var context = FileParseContext(
            sessionID: file.identity,
            turnID: file.identity,
            model: ModelIdentity(raw: "unknown", display: "unknown")
        )
        if startOffset > 0 && !rebuiltFile {
            context = try rehydrateContext(from: file.url, prefixOffset: startOffset, fallback: context)
        }

        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = []
        var rollback = false

        for (line, ordinalFallback) in zip(completeLines.lines, completeLines.ordinals) {
            switch CodexRolloutParser.parseLine(line) {
            case .ignored:
                continue
            case .unknownSchema:
                diagnostics.append(SourceDiagnostic(code: "UNKNOWN_SCHEMA", sourceID: sourceID))
            case let .sessionMeta(id, _, _):
                context.sessionID = id
            case let .turnContext(turnID, model, _, _):
                if let turnID { context.turnID = turnID }
                if let model {
                    context.model = ModelIdentity(raw: model, display: model)
                }
            case let .turnLifecycle(turnID, _, _):
                context.turnID = turnID
            case let .tokenCount(totalOutput, _, timestamp, ordinal):
                let watermark = state.watermarks[file.identity] ?? 0
                if totalOutput < watermark {
                    if forceRebuild {
                        if totalOutput > 0 {
                            observations.append(
                                observation(
                                    fileIdentity: file.identity,
                                    ordinal: ordinal ?? UInt64(ordinalFallback),
                                    context: context,
                                    outputTokens: totalOutput,
                                    timestamp: timestamp,
                                    clock: clock
                                )
                            )
                        }
                        state.watermarks[file.identity] = totalOutput
                    } else {
                        rollback = true
                    }
                } else if totalOutput > watermark {
                    observations.append(
                        observation(
                            fileIdentity: file.identity,
                            ordinal: ordinal ?? UInt64(ordinalFallback),
                            context: context,
                            outputTokens: totalOutput - watermark,
                            timestamp: timestamp,
                            clock: clock
                        )
                    )
                    state.watermarks[file.identity] = totalOutput
                }
            }
            if rollback { break }
        }

        let prefixHandle = try FileHandle(forReadingFrom: file.url)
        defer { try? prefixHandle.close() }
        let prefix = try prefixHandle.read(upToCount: Int(newOffset)) ?? Data()
        state.files[file.identity] = SourceFileCursor(
            fileIdentity: file.identity,
            locator: file.locator,
            generation: generation,
            prefixFingerprint: CodexRolloutParser.fingerprint(prefix),
            offset: newOffset,
            parserVersion: CodexRolloutParser.semanticVersion
        )

        return FileScanResult(
            observations: observations,
            diagnostics: diagnostics,
            rebuiltFile: rebuiltFile,
            rollback: rollback
        )
    }

    private func observation(
        fileIdentity: String,
        ordinal: UInt64,
        context: FileParseContext,
        outputTokens: Int,
        timestamp: String?,
        clock: any Clock
    ) -> UsageObservation {
        UsageObservation(
            observationIdentity: "codex-rollout:\(fileIdentity):\(ordinal)",
            schemaVersion: CodexRolloutParser.schemaVersion,
            codingAgent: .codex,
            model: context.model,
            sessionID: context.sessionID,
            turnID: context.turnID,
            observedAt: CodexRolloutParser.parseTimestamp(timestamp) ?? clock.now,
            outputTokens: outputTokens
        )
    }

    private func completeLines(in data: Data) -> (lines: [String], ordinals: [Int], consumed: Int64) {
        var lines: [String] = []
        var ordinals: [Int] = []
        var start = data.startIndex
        var consumed = 0
        var index = 0
        while let newline = data[start...].firstIndex(of: 10) {
            let lineData = data[start..<newline]
            if let line = String(data: Data(lineData), encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                    ordinals.append(index)
                }
            }
            let next = data.index(after: newline)
            consumed += data.distance(from: start, to: next)
            start = next
            index += 1
        }
        return (lines, ordinals, Int64(consumed))
    }

    private func discoverRollouts() throws -> [DiscoveredRollout] {
        var discovered: [String: DiscoveredRollout] = [:]
        for subdirectory in ["archived_sessions", "sessions"] {
            let root = sessionRoot.appendingPathComponent(subdirectory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard let identity = CodexRolloutParser.fileIdentity(fromFileName: name) else { continue }
                let locator = relativeLocator(for: url)
                let item = DiscoveredRollout(identity: identity, locator: locator, url: url)
                if subdirectory == "sessions" || discovered[identity] == nil {
                    discovered[identity] = item
                }
            }
        }
        return discovered.values.sorted { $0.locator < $1.locator }
    }

    private func relativeLocator(for url: URL) -> String {
        let rootPath = sessionRoot.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            let sliced = String(filePath.dropFirst(rootPath.count))
            return sliced.hasPrefix("/") ? String(sliced.dropFirst()) : sliced
        }
        return url.lastPathComponent
    }

    private func rehydrateContext(
        from url: URL,
        prefixOffset: Int64,
        fallback: FileParseContext
    ) throws -> FileParseContext {
        var context = fallback
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: Int(prefixOffset)) ?? Data()
        let parsed = completeLines(in: prefix)
        for line in parsed.lines {
            switch CodexRolloutParser.parseLine(line) {
            case let .sessionMeta(id, _, _):
                context.sessionID = id
            case let .turnContext(turnID, model, _, _):
                if let turnID { context.turnID = turnID }
                if let model {
                    context.model = ModelIdentity(raw: model, display: model)
                }
            case let .turnLifecycle(turnID, _, _):
                context.turnID = turnID
            default:
                continue
            }
        }
        return context
    }
}

private struct DiscoveredRollout {
    var identity: String
    var locator: String
    var url: URL
}

private struct FileParseContext {
    var sessionID: String
    var turnID: String
    var model: ModelIdentity
}

private struct FileScanResult {
    var observations: [UsageObservation]
    var diagnostics: [SourceDiagnostic]
    var rebuiltFile: Bool
    var rollback: Bool
}

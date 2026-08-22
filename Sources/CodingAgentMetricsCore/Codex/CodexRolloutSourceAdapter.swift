import Foundation

public struct CodexRolloutSourceAdapter: IncrementalSourceAdapter {
    static let maximumAppendBytesPerFile = 512 * 1_024
    static let maximumRolloutFiles = 256
    private static let maximumDirectoryEntries = 4_096
    private static let fingerprintSampleBytes = 64 * 1_024

    public var sessionRoot: URL

    public init(sessionRoot: URL) {
        self.sessionRoot = sessionRoot
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(sessionRoot: CodexHome.resolve(environment: environment))
    }

    public var sourceID: String { CodexRolloutParser.sourceID }

    public var sourceOwnership: SourceOwnership {
        SourceOwnership(
            sourceID: sourceID,
            impacts: [.usage],
            codingAgents: [.codex],
            channels: [.codexRollout]
        )
    }

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
                health: SourceHealth.usage(
                    sourceID: sourceID,
                    codingAgent: .codex,
                    channel: .codexRollout,
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
        var rebuiltFileIdentities: [String] = []
        var rebuildSource = false
        var seenIdentities = Set<String>()

        let discovery = try discoverRollouts()
        let files = discovery.files
        let missingKnownFiles = !Set(working.files.keys).subtracting(discovery.identities).isEmpty
        if files.isEmpty, !working.files.isEmpty {
            return SourceScan(
                observations: [],
                state: working,
                rebuildSource: false,
                diagnostics: working.diagnosticCodes.map { SourceDiagnostic(code: $0, sourceID: sourceID) },
                health: SourceHealth.usage(
                    sourceID: sourceID,
                    codingAgent: .codex,
                    channel: .codexRollout,
                    isHealthy: false,
                    diagnosticCode: "SOURCE_UNAVAILABLE"
                )
            )
        }

        var diagnostics: [SourceDiagnostic] = discovery.isTruncated
            ? [SourceDiagnostic(code: "SOURCE_OVERLOADED", sourceID: sourceID)]
            : []
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
        let health = SourceHealth.usage(
            sourceID: sourceID,
            codingAgent: .codex,
            channel: .codexRollout,
            isHealthy: !missingKnownFiles && uniqueDiagnostics.isEmpty,
            diagnosticCode: missingKnownFiles ? "SOURCE_UNAVAILABLE" : uniqueDiagnostics.first?.code
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
        let generation = "\(inode)"
        let lastModifiedAt = attributes[.modificationDate] as? Date
        let prior = forceRebuild ? nil : state.files[file.identity]

        var startOffset: Int64 = prior?.offset ?? 0
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
                if prior.parserContext == nil {
                    startOffset = 0
                    rebuiltFile = true
                } else if try cursorFingerprint(file.url, upTo: prior.offset) != prior.prefixFingerprint {
                    startOffset = 0
                    rebuiltFile = true
                }
            }
        }
        if rebuiltFile {
            startOffset = 0
            state.watermarks = state.watermarks.filter { key, _ in key != file.identity && !key.hasPrefix("\(file.identity):") }
            state.watermarks[file.identity] = 0
        }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        let appended = try handle.read(upToCount: Self.maximumAppendBytesPerFile) ?? Data()
        let completeLines = BoundedJSONL.completeLines(
            in: appended,
            maximumBatchBytes: Self.maximumAppendBytesPerFile,
            discardingOversizedLine: !rebuiltFile && prior?.discardingOversizedLine == true
        )
        let consumed = completeLines.consumed
        let newOffset = startOffset + consumed

        var context = prior?.parserContext ?? SourceParserContext(
            sessionID: file.identity,
            turnID: file.identity,
            model: ModelIdentity(raw: "unknown", display: "unknown")
        )
        if rebuiltFile {
            context = SourceParserContext(
                sessionID: file.identity,
                turnID: file.identity,
                model: ModelIdentity(raw: "unknown", display: "unknown")
            )
        }

        var observations: [UsageObservation] = []
        var diagnostics: [SourceDiagnostic] = []
        if completeLines.encounteredOversizedLine {
            diagnostics.append(SourceDiagnostic(code: "SOURCE_LINE_TOO_LONG", sourceID: sourceID))
        }
        if startOffset + Int64(appended.count) < size {
            diagnostics.append(SourceDiagnostic(code: "SOURCE_OVERLOADED", sourceID: sourceID))
        }
        var rollback = false

        for line in completeLines.lines {
            guard let value = line.value else { continue }
            switch CodexRolloutParser.parseLine(value) {
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
            case let .tokenCount(total, _, timestamp, ordinal):
                guard let totalOutput = total.outputTotal else { continue }
                let watermark = state.watermarks[file.identity] ?? 0
                if totalOutput < watermark {
                    if forceRebuild {
                        observations.removeAll()
                        if totalOutput > 0 {
                            observations.append(
                                observation(
                                    fileIdentity: file.identity,
                                    ordinal: ordinal ?? UInt64(line.ordinal),
                                    context: context,
                                    outputTokens: totalOutput,
                                    tokenParts: deltaParts(total: total, fileIdentity: file.identity, state: &state, reset: true),
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
                            ordinal: ordinal ?? UInt64(line.ordinal),
                            context: context,
                            outputTokens: totalOutput - watermark,
                            tokenParts: deltaParts(total: total, fileIdentity: file.identity, state: &state),
                            timestamp: timestamp,
                            clock: clock
                        )
                    )
                    state.watermarks[file.identity] = totalOutput
                }
            }
            if rollback { break }
        }

        state.files[file.identity] = SourceFileCursor(
            fileIdentity: file.identity,
            locator: file.locator,
            generation: generation,
            prefixFingerprint: try cursorFingerprint(file.url, upTo: newOffset),
            offset: newOffset,
            parserVersion: CodexRolloutParser.semanticVersion,
            lastObservedSize: size,
            lastModifiedAt: lastModifiedAt,
            parserContext: context,
            discardingOversizedLine: completeLines.discardingOversizedLine
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
        context: SourceParserContext,
        outputTokens: Int,
        tokenParts: TokenParts? = nil,
        timestamp: String?,
        clock: any Clock
    ) -> UsageObservation {
        UsageObservation(
            observationIdentity: "codex-rollout:\(fileIdentity):\(ordinal)",
            schemaVersion: CodexRolloutParser.schemaVersion,
            sourceID: CodexRolloutParser.sourceID,
            codingAgent: .codex,
            model: context.model,
            sessionID: context.sessionID,
            turnID: context.turnID,
            observedAt: CodexRolloutParser.parseTimestamp(timestamp)!,
            outputTokens: outputTokens,
            tokenParts: tokenParts
        )
    }

    /// Rollout counts are cumulative.  Cache write deliberately stays nil: its
    /// relationship to input tokens is not documented, so it is never added.
    private func deltaParts(total: CodexRawTokenUsage, fileIdentity: String, state: inout SourceState, reset: Bool = false) -> TokenParts? {
        guard let input = total.inputTotal, let cached = total.cachedInput,
              let output = total.outputTotal, let reasoning = total.reasoningOutput else { return nil }
        let values = [
            "input": input,
            "cached": cached,
            "output": output,
            "reasoning": reasoning,
        ]
        let watermarks = Dictionary(uniqueKeysWithValues: values.keys.map { key in
            (key, reset ? 0 : (state.watermarks["\(fileIdentity):\(key)"] ?? 0))
        })
        let deltas = Dictionary(uniqueKeysWithValues: values.map { key, value in
            (key, value - (watermarks[key] ?? 0))
        })
        guard cached <= input, reasoning <= output,
              deltas.values.allSatisfy({ $0 >= 0 }),
              let inputDelta = deltas["input"], let cacheDelta = deltas["cached"],
              let outputDelta = deltas["output"], let reasoningDelta = deltas["reasoning"],
              cacheDelta <= inputDelta, reasoningDelta <= outputDelta else { return nil }

        for (key, value) in values {
            state.watermarks["\(fileIdentity):\(key)"] = value
        }
        return TokenParts(
            inputUncached: max(0, inputDelta - cacheDelta),
            cacheRead: cacheDelta,
            cacheWrite: nil,
            outputVisible: max(0, outputDelta - reasoningDelta),
            reasoning: reasoningDelta,
            normalizedBurnTotal: max(0, inputDelta - cacheDelta) + cacheDelta + max(0, outputDelta - reasoningDelta) + reasoningDelta
        )
    }

    private func discoverRollouts() throws -> RolloutDiscovery {
        var discovered: [String: DiscoveredRollout] = [:]
        var entryCount = 0
        for subdirectory in ["archived_sessions", "sessions"] {
            let root = sessionRoot.appendingPathComponent(subdirectory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                entryCount += 1
                guard entryCount <= Self.maximumDirectoryEntries else {
                    throw CodexRolloutAdapterError.discoveryLimitExceeded
                }
                let name = url.lastPathComponent
                guard let identity = CodexRolloutParser.fileIdentity(fromFileName: name) else { continue }
                let locator = relativeLocator(for: url)
                let item = DiscoveredRollout(
                    identity: identity,
                    locator: locator,
                    url: url,
                    modifiedAt: modificationDate(for: url)
                )
                if subdirectory == "sessions" || discovered[identity] == nil {
                    discovered[identity] = item
                }
            }
        }
        let mostRecent = discovered.values.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
            return lhs.locator < rhs.locator
        }
        return RolloutDiscovery(
            files: Array(mostRecent.prefix(Self.maximumRolloutFiles)).sorted { $0.locator < $1.locator },
            identities: Set(discovered.keys),
            isTruncated: discovered.count > Self.maximumRolloutFiles
        )
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
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

    private func cursorFingerprint(_ url: URL, upTo offset: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = Int64(Self.fingerprintSampleBytes)
        var data = try handle.read(upToCount: Int(min(offset, sample))) ?? Data()
        if offset > sample {
            try handle.seek(toOffset: UInt64(max(sample, offset - sample)))
            data.append(try handle.read(upToCount: Int(min(sample, offset - sample))) ?? Data())
        }
        return CodexRolloutParser.fingerprint(data)
    }
}

private struct DiscoveredRollout {
    var identity: String
    var locator: String
    var url: URL
    var modifiedAt: Date
}

private struct RolloutDiscovery {
    var files: [DiscoveredRollout]
    var identities: Set<String>
    var isTruncated: Bool
}

private struct FileScanResult {
    var observations: [UsageObservation]
    var diagnostics: [SourceDiagnostic]
    var rebuiltFile: Bool
    var rollback: Bool
}

private enum CodexRolloutAdapterError: Error {
    case discoveryLimitExceeded
}

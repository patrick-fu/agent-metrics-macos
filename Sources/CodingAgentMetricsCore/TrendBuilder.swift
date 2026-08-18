import Foundation

public struct TrendBuilder: Sendable {
    public static let maximumPointsPerSeries = 180

    private struct PartTotal {
        var count = 0
        var value = 0
    }

    private struct PartAggregate {
        var factCount = 0
        var totals: [TrendTokenPart: PartTotal] = [:]

        mutating func add(_ parts: TokenParts?) {
            factCount += 1
            for part in TrendTokenPart.allCases {
                guard let value = partValue(part, in: parts) else { continue }
                totals[part, default: PartTotal()].count += 1
                totals[part, default: PartTotal()].value += value
            }
        }

        mutating func merge(_ other: PartAggregate) {
            factCount += other.factCount
            for (part, total) in other.totals {
                totals[part, default: PartTotal()].count += total.count
                totals[part, default: PartTotal()].value += total.value
            }
        }

        func value(for part: TrendTokenPart, requireComplete: Bool) -> Int? {
            guard let total = totals[part], total.count > 0 else { return nil }
            return !requireComplete || total.count == factCount ? total.value : nil
        }

        private func partValue(_ part: TrendTokenPart, in parts: TokenParts?) -> Int? {
            switch part {
            case .inputUncached: parts?.inputUncached
            case .cacheRead: parts?.cacheRead
            case .cacheWrite: parts?.cacheWrite
            case .outputVisible: parts?.outputVisible
            case .reasoning: parts?.reasoning
            }
        }
    }

    private struct BucketAggregate {
        var amount = 0
        var parts = PartAggregate()

        mutating func add(amount: Int, parts: TokenParts?) {
            self.amount += amount
            self.parts.add(parts)
        }

        mutating func merge(_ other: BucketAggregate) {
            amount += other.amount
            parts.merge(other.parts)
        }
    }

    public init() {}

    public func build(
        facts: [UsageFact],
        now: Date,
        filter: MetricFilter = .all,
        sourceHealth: [SourceHealth] = []
    ) -> TrendSnapshot {
        let filtered = facts.filter(filter.includes)
        let selection = AuthorityCoalescing.select(filtered)
        let health = relevantHealth(sourceHealth, filter: filter, facts: filtered)
        let scope: OutputThroughputScope = filter.agents.isAll && filter.models.isAll ? .all : .selected
        let emptyReason: UnavailableReasonCode = filtered.isEmpty && !facts.isEmpty && scope == .selected
            ? .filterExcludesObservations : .noObservations
        return TrendSnapshot(
            outputThroughput: chart(facts: selection.facts, originalFacts: filtered, now: now, windowSeconds: OutputThroughputDefinition.windowSeconds, bucketSeconds: 5, kind: .output, conflict: selection.hasConflict, sourceHealth: health, scope: scope, emptyReason: emptyReason),
            tokenBurn: chart(facts: selection.facts, originalFacts: filtered, now: now, windowSeconds: TokenBurnDefinition.windowSeconds, bucketSeconds: 30, kind: .burn, conflict: selection.hasConflict, sourceHealth: health, scope: scope, emptyReason: emptyReason),
            // Calls KPI retains one stable identity through an authority conflict.
            calls: chart(facts: filtered, originalFacts: filtered, now: now, windowSeconds: CallsDefinition.windowSeconds, bucketSeconds: 30, kind: .calls, conflict: selection.hasConflict, sourceHealth: health, scope: scope, emptyReason: emptyReason),
            generatedAt: now,
            sourceHealth: health
        )
    }

    private enum Kind { case output, burn, calls }

    private func chart(facts: [UsageFact], originalFacts: [UsageFact], now: Date, windowSeconds: Int, bucketSeconds: Int, kind: Kind, conflict: Bool, sourceHealth: [SourceHealth], scope: OutputThroughputScope, emptyReason: UnavailableReasonCode) -> TrendChart {
        let duration = TimeInterval(bucketSeconds)
        let closedEnd = floor(now.timeIntervalSince1970 / duration) * duration
        let start = closedEnd - TimeInterval(windowSeconds)
        let hasOpenBucket = now.timeIntervalSince1970 > closedEnd
        let completeStarts = stride(from: start, to: closedEnd, by: duration).map { Date(timeIntervalSince1970: $0) }
        let starts = Array(
            (completeStarts + (hasOpenBucket ? [Date(timeIntervalSince1970: closedEnd)] : []))
                .suffix(Self.maximumPointsPerSeries)
        )
        let completeCount = starts.count - (hasOpenBucket ? 1 : 0)
        // Open buckets are placeholders only; no rank or metric metadata uses them.
        let degraded = sourceHealth.filter { !$0.isHealthy }
        let completeFacts = facts.filter {
            $0.observedAt.timeIntervalSince1970 >= start && $0.observedAt.timeIntervalSince1970 < closedEnd
        }
        let originalCompleteFacts = originalFacts.filter {
            $0.observedAt.timeIntervalSince1970 >= start && $0.observedAt.timeIntervalSince1970 < closedEnd
        }
        let capable = deduplicateCalls(
            completeFacts.filter { supports($0, kind: kind) && $0.measurementQuality != .unavailable },
            kind: kind
        )
        let identities = Dictionary(grouping: capable, by: { $0.model.raw })
        let displayNames = identities.mapValues { $0.map(\.model.display).min() ?? $0[0].model.raw }
        let totals = identities.mapValues { $0.reduce(0) { $0 + amount($1, kind: kind) } }
        let ordered = identities.keys.sorted { lhs, rhs in
            let leftTotal = totals[lhs, default: 0], rightTotal = totals[rhs, default: 0]
            if leftTotal != rightTotal { return leftTotal > rightTotal }
            let leftDisplay = displayNames[lhs, default: lhs], rightDisplay = displayNames[rhs, default: rhs]
            return leftDisplay == rightDisplay ? lhs < rhs : leftDisplay < rightDisplay
        }
        let groups: [(TrendSeriesIdentity, String, TrendSeriesRole, Set<String>)]
        if kind == .calls {
            groups = ordered.isEmpty ? [] : [(.aggregate("calls"), "Calls", .model, Set(ordered))]
        } else {
            let visible = ordered.count > 5 ? Array(ordered.prefix(4)) : ordered
            let hidden = Set(ordered).subtracting(visible)
            let titleCounts = Dictionary(grouping: visible, by: { displayNames[$0, default: $0] }).mapValues(\.count)
            groups = visible.map { raw in
                let display = displayNames[raw, default: raw]
                let title = titleCounts[display, default: 0] > 1 ? "\(display) (\(raw))" : display
                return (.model(raw), title, .model, Set([raw]))
            } + (hidden.isEmpty ? [] : [(.other, "Other", .other, hidden)])
        }
        let aggregates = bucketAggregates(facts: capable, duration: duration, kind: kind)

        let qualities = capable.map(\.measurementQuality)
        let anyEstimated = qualities.contains(.estimated)
        let mixedQuality = Set(qualities).count > 1
        let hasUnsupported = !originalCompleteFacts.isEmpty && capable.count != originalCompleteFacts.count
        let retainedHealth = degraded.filter { health in
            originalFacts.contains { matches(health, fact: $0) }
        }
        let coverage: Coverage = conflict || hasUnsupported || mixedQuality || !degraded.isEmpty ? .partial : .complete
        let authority = authority(in: capable) ?? authority(in: completeFacts) ?? authority(in: originalCompleteFacts)
            ?? authority(in: originalFacts) ?? "unavailable"
        let state: DataState?
        if capable.isEmpty {
            state = !retainedHealth.isEmpty
                ? .stale
                : (!degraded.isEmpty ? .unavailable : (originalFacts.isEmpty ? .absent : .stale))
        } else {
            state = retainedHealth.isEmpty ? nil : .stale
        }
        let quality = MeasurementQuality.combined(qualities, derivedResult: true)
        let series = groups.map { identity, title, role, group in
            let emphasis: TrendSeriesEmphasis = role == .other ? .other : (anyEstimated ? .estimated : (coverage == .partial ? .partial : .normal))
            return TrendSeries(identity: identity, title: title, colorSlot: role == .other ? "other" : (group.first ?? "calls"), role: role, emphasis: emphasis, buckets: buckets(starts: starts, completeCount: completeCount, duration: duration, aggregates: aggregates, models: group, kind: kind, bucketSeconds: bucketSeconds))
        }
        let partSeries = kind == .burn ? tokenPartSeries(starts: starts, completeCount: completeCount, duration: duration, aggregates: aggregates, bucketSeconds: bucketSeconds) : []
        let degradation = degraded.first.flatMap { health -> (UnavailableReasonCode, MetricAction?)? in
            guard let reason = health.reasonCode else { return nil }
            return (reason, health.recommendedAction ?? MetricAction.recommended(for: reason))
        }
        let noDataReason = capable.isEmpty ? (conflict ? UnavailableReasonCode.authorityConflict : (degradation?.0 ?? emptyReason)) : degradation?.0
        let lastUpdated = retainedHealth.compactMap { health in
            originalFacts.filter { matches(health, fact: $0) }.map(\.observedAt).max()
        }.min() ?? capable.map(\.observedAt).max() ?? originalFacts.map(\.observedAt).max()
        let retained = !retainedHealth.isEmpty || (capable.isEmpty && !originalFacts.isEmpty)
        return TrendChart(
            windowSeconds: windowSeconds,
            bucketSeconds: bucketSeconds,
            series: series,
            partSeries: partSeries,
            measurementQuality: quality,
            dataState: state,
            coverage: coverage,
            sourceAuthority: conflict ? "mixed" : authority,
            freshness: .observed(at: lastUpdated, now: now, retained: retained),
            sampleCount: capable.count,
            definitionVersion: definitionVersion(for: kind),
            scope: scope,
            unavailableReason: noDataReason,
            recommendedAction: degradation?.1 ?? MetricAction.recommended(for: noDataReason),
            table: accessibleTable(
                starts: starts,
                duration: duration,
                series: series,
                partSeries: partSeries,
                quality: quality,
                dataState: state,
                coverage: coverage
            )
        )
    }

    private func bucketAggregates(
        facts: [UsageFact],
        duration: TimeInterval,
        kind: Kind
    ) -> [Int64: [String: BucketAggregate]] {
        var result: [Int64: [String: BucketAggregate]] = [:]
        for fact in facts {
            let key = bucketKey(fact.observedAt, duration: duration)
            var modelBuckets = result[key, default: [:]]
            var aggregate = modelBuckets[fact.model.raw, default: BucketAggregate()]
            aggregate.add(amount: amount(fact, kind: kind), parts: fact.tokenParts)
            modelBuckets[fact.model.raw] = aggregate
            result[key] = modelBuckets
        }
        return result
    }

    private func buckets(starts: [Date], completeCount: Int, duration: TimeInterval, aggregates: [Int64: [String: BucketAggregate]], models: Set<String>, kind: Kind, bucketSeconds: Int) -> [TrendBucket] {
        starts.enumerated().map { index, bucketStart in
            let end = bucketStart.addingTimeInterval(duration)
            guard index < completeCount else { return TrendBucket(start: bucketStart, end: end, isComplete: false, value: nil, absoluteCount: nil) }
            let modelBuckets = aggregates[bucketKey(bucketStart, duration: duration), default: [:]]
            let merged = models.compactMap { modelBuckets[$0] }.reduce(nil) { current, next -> BucketAggregate? in
                guard var current else { return next }
                current.merge(next)
                return current
            }
            guard let merged else { return TrendBucket(start: bucketStart, end: end, isComplete: true, value: nil, absoluteCount: nil) }
            return TrendBucket(start: bucketStart, end: end, isComplete: true, value: normalized(merged.amount, kind: kind, bucketSeconds: bucketSeconds), absoluteCount: merged.amount, parts: kind == .burn ? tokenParts(from: merged.parts, requireComplete: true) : nil)
        }
    }

    private func tokenPartSeries(starts: [Date], completeCount: Int, duration: TimeInterval, aggregates: [Int64: [String: BucketAggregate]], bucketSeconds: Int) -> [TrendPartSeries] {
        TrendTokenPart.allCases.map { part in
            TrendPartSeries(part: part, buckets: starts.enumerated().map { index, bucketStart in
                let end = bucketStart.addingTimeInterval(duration)
                guard index < completeCount else { return TrendBucket(start: bucketStart, end: end, isComplete: false, value: nil, absoluteCount: nil) }
                let modelBuckets = aggregates[bucketKey(bucketStart, duration: duration), default: [:]]
                var merged = PartAggregate()
                for aggregate in modelBuckets.values { merged.merge(aggregate.parts) }
                guard let total = merged.value(for: part, requireComplete: false) else { return TrendBucket(start: bucketStart, end: end, isComplete: true, value: nil, absoluteCount: nil) }
                return TrendBucket(start: bucketStart, end: end, isComplete: true, value: Double(total) / Double(bucketSeconds) * 60, absoluteCount: total)
            })
        }
    }

    private func bucketKey(_ date: Date, duration: TimeInterval) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / duration))
    }

    private func tokenParts(from aggregate: PartAggregate, requireComplete: Bool) -> TokenParts {
        TokenParts(
            inputUncached: aggregate.value(for: .inputUncached, requireComplete: requireComplete),
            cacheRead: aggregate.value(for: .cacheRead, requireComplete: requireComplete),
            cacheWrite: aggregate.value(for: .cacheWrite, requireComplete: requireComplete),
            outputVisible: aggregate.value(for: .outputVisible, requireComplete: requireComplete),
            reasoning: aggregate.value(for: .reasoning, requireComplete: requireComplete)
        )
    }

    private func accessibleTable(
        starts: [Date],
        duration: TimeInterval,
        series: [TrendSeries],
        partSeries: [TrendPartSeries],
        quality: MeasurementQuality,
        dataState: DataState?,
        coverage: Coverage
    ) -> AccessibleTrendTable {
        let columns: [AccessibleTrendColumn]
        let rows: [AccessibleTrendRow]
        if !partSeries.isEmpty {
            columns = partSeries.map {
                AccessibleTrendColumn(
                    title: $0.part.title,
                    identityLabel: $0.part.title,
                    emphasisText: $0.part.title,
                    symbol: $0.part.symbol
                )
            }
            rows = starts.enumerated().map { index, start in
                let buckets = partSeries.map { index < $0.buckets.count ? $0.buckets[index] : nil }
                return AccessibleTrendRow(
                    bucketStart: start,
                    bucketEnd: start.addingTimeInterval(duration),
                    cells: buckets.map { $0?.absoluteCount.map(String.init) ?? "—" },
                    isComplete: buckets.contains { $0?.isComplete == true }
                )
            }
        } else {
            columns = series.map {
                AccessibleTrendColumn(
                    title: $0.title,
                    identityLabel: $0.identity.accessibilityLabel,
                    emphasisText: $0.emphasis.accessibilityText,
                    symbol: $0.emphasis.symbol
                )
            }
            rows = starts.enumerated().map { index, start in
                let buckets = series.map { index < $0.buckets.count ? $0.buckets[index] : nil }
                return AccessibleTrendRow(
                    bucketStart: start,
                    bucketEnd: start.addingTimeInterval(duration),
                    cells: buckets.map { $0?.absoluteCount.map(String.init) ?? "—" },
                    isComplete: buckets.contains { $0?.isComplete == true }
                )
            }
        }
        return AccessibleTrendTable(
            columnTitles: columns.map(\.title),
            rows: rows,
            columns: columns,
            qualityText: quality.displayLabel,
            dataStateText: dataState?.displayLabel ?? "-",
            coverageText: coverage.displayLabel
        )
    }

    private func supports(_ fact: UsageFact, kind: Kind) -> Bool {
        switch kind { case .output: true; case .burn: fact.tokenParts?.normalizedBurnTotal != nil; case .calls: fact.modelCallCapability == .available && fact.modelCallID?.isEmpty == false }
    }
    private func amount(_ fact: UsageFact, kind: Kind) -> Int {
        switch kind { case .output: fact.outputTokens; case .burn: fact.tokenParts?.normalizedBurnTotal ?? 0; case .calls: 1 }
    }
    private func deduplicateCalls(_ facts: [UsageFact], kind: Kind) -> [UsageFact] {
        guard kind == .calls else { return facts }
        var seen = Set<String>()
        return facts.filter { fact in guard let call = fact.modelCallID else { return false }; return seen.insert("\(fact.codingAgent.rawValue):\(call)").inserted }
    }
    private func normalized(_ amount: Int, kind: Kind, bucketSeconds: Int) -> Double {
        switch kind { case .output: Double(amount) / Double(bucketSeconds); case .burn, .calls: Double(amount) / Double(bucketSeconds) * 60 }
    }
    private func authority(in facts: [UsageFact]) -> String? {
        let authorities = Set(facts.map(\.authority)); return authorities.count == 1 ? authorities.first : (authorities.isEmpty ? nil : "mixed")
    }
    private func definitionVersion(for kind: Kind) -> String {
        switch kind {
        case .output: OutputThroughputDefinition.version
        case .burn: TokenBurnDefinition.version
        case .calls: CallsDefinition.version
        }
    }
    private func relevantHealth(_ health: [SourceHealth], filter: MetricFilter, facts: [UsageFact]) -> [SourceHealth] {
        health.filter { item in
            guard item.impacts.contains(.usage) else { return false }
            if filter.agents.isAll && filter.models.isAll { return true }
            if facts.contains(where: { matches(item, fact: $0) }) { return true }
            if !item.impactedAgents.isEmpty && !filter.agents.isAll {
                return item.impactedAgents.map(\.rawValue).contains { filter.agents.selected.contains($0) }
            }
            if !filter.models.isAll && facts.isEmpty { return true }
            return false
        }
    }
    private func matches(_ health: SourceHealth, fact: UsageFact) -> Bool {
        fact.sourceID != "unknown" && health.sourceID == fact.sourceID
    }
    private func partValue(_ part: TrendTokenPart, in parts: TokenParts?) -> Int? {
        switch part { case .inputUncached: parts?.inputUncached; case .cacheRead: parts?.cacheRead; case .cacheWrite: parts?.cacheWrite; case .outputVisible: parts?.outputVisible; case .reasoning: parts?.reasoning }
    }
}

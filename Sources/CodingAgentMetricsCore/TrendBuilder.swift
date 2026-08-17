import Foundation

public struct TrendBuilder: Sendable {
    public init() {}

    public func build(facts: [UsageFact], now: Date, filter: MetricFilter = .all) -> TrendSnapshot {
        let filtered = facts.filter(filter.includes)
        let selection = AuthorityCoalescing.select(filtered)
        return TrendSnapshot(
            outputThroughput: chart(facts: selection.facts, originalFacts: filtered, now: now, windowSeconds: OutputThroughputDefinition.windowSeconds, bucketSeconds: 5, kind: .output, conflict: selection.hasConflict),
            tokenBurn: chart(facts: selection.facts, originalFacts: filtered, now: now, windowSeconds: TokenBurnDefinition.windowSeconds, bucketSeconds: 30, kind: .burn, conflict: selection.hasConflict),
            // Calls KPI retains one stable identity through an authority conflict.
            calls: chart(facts: filtered, originalFacts: filtered, now: now, windowSeconds: CallsDefinition.windowSeconds, bucketSeconds: 30, kind: .calls, conflict: selection.hasConflict)
        )
    }

    private enum Kind { case output, burn, calls }

    private func chart(facts: [UsageFact], originalFacts: [UsageFact], now: Date, windowSeconds: Int, bucketSeconds: Int, kind: Kind, conflict: Bool) -> TrendChart {
        let duration = TimeInterval(bucketSeconds)
        let closedEnd = floor(now.timeIntervalSince1970 / duration) * duration
        let start = closedEnd - TimeInterval(windowSeconds)
        let hasOpenBucket = now.timeIntervalSince1970 > closedEnd
        let completeStarts = stride(from: start, to: closedEnd, by: duration).map { Date(timeIntervalSince1970: $0) }
        let starts = completeStarts + (hasOpenBucket ? [Date(timeIntervalSince1970: closedEnd)] : [])
        // Open buckets are placeholders only; no rank or metric metadata uses them.
        let completeFacts = facts.filter { $0.observedAt.timeIntervalSince1970 >= start && $0.observedAt.timeIntervalSince1970 < closedEnd }
        let originalCompleteFacts = originalFacts.filter { $0.observedAt.timeIntervalSince1970 >= start && $0.observedAt.timeIntervalSince1970 < closedEnd }
        let capable = deduplicateCalls(completeFacts.filter { supports($0, kind: kind) }, kind: kind)
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

        let anyEstimated = capable.contains { $0.measurementQuality == .estimated }
        let hasUnsupported = !originalCompleteFacts.isEmpty && capable.count != originalCompleteFacts.count
        let coverage: Coverage = conflict || hasUnsupported ? .partial : .complete
        let authority = authority(in: capable) ?? authority(in: completeFacts) ?? authority(in: originalCompleteFacts) ?? "unavailable"
        let state: DataState? = capable.isEmpty ? (originalFacts.isEmpty ? .absent : .stale) : nil
        let quality: MeasurementQuality = capable.isEmpty ? .unavailable : (anyEstimated ? .estimated : .derived)
        let series = groups.map { identity, title, role, group in
            let emphasis: TrendSeriesEmphasis = role == .other ? .other : (anyEstimated ? .estimated : (coverage == .partial ? .partial : .normal))
            return TrendSeries(identity: identity, title: title, colorSlot: role == .other ? "other" : (group.first ?? "calls"), role: role, emphasis: emphasis, buckets: buckets(starts: starts, completeCount: completeStarts.count, duration: duration, facts: capable.filter { group.contains($0.model.raw) }, kind: kind, bucketSeconds: bucketSeconds))
        }
        let partSeries = kind == .burn ? tokenPartSeries(starts: starts, completeCount: completeStarts.count, duration: duration, facts: capable, bucketSeconds: bucketSeconds) : []
        return TrendChart(windowSeconds: windowSeconds, bucketSeconds: bucketSeconds, series: series, partSeries: partSeries, measurementQuality: quality, dataState: state, coverage: coverage, sourceAuthority: conflict ? "mixed" : authority, table: accessibleTable(starts: starts, duration: duration, series: series, partSeries: partSeries))
    }

    private func buckets(starts: [Date], completeCount: Int, duration: TimeInterval, facts: [UsageFact], kind: Kind, bucketSeconds: Int) -> [TrendBucket] {
        starts.enumerated().map { index, bucketStart in
            let end = bucketStart.addingTimeInterval(duration)
            guard index < completeCount else { return TrendBucket(start: bucketStart, end: end, isComplete: false, value: nil, absoluteCount: nil) }
            let members = facts.filter { $0.observedAt >= bucketStart && $0.observedAt < end }
            guard !members.isEmpty else { return TrendBucket(start: bucketStart, end: end, isComplete: true, value: nil, absoluteCount: nil) }
            let total = members.reduce(0) { $0 + amount($1, kind: kind) }
            return TrendBucket(start: bucketStart, end: end, isComplete: true, value: normalized(total, kind: kind, bucketSeconds: bucketSeconds), absoluteCount: total, parts: kind == .burn ? merge(parts: members.compactMap(\.tokenParts)) : nil)
        }
    }

    private func tokenPartSeries(starts: [Date], completeCount: Int, duration: TimeInterval, facts: [UsageFact], bucketSeconds: Int) -> [TrendPartSeries] {
        TrendTokenPart.allCases.map { part in
            TrendPartSeries(part: part, buckets: starts.enumerated().map { index, bucketStart in
                let end = bucketStart.addingTimeInterval(duration)
                guard index < completeCount else { return TrendBucket(start: bucketStart, end: end, isComplete: false, value: nil, absoluteCount: nil) }
                let values = facts.filter { $0.observedAt >= bucketStart && $0.observedAt < end }.compactMap { partValue(part, in: $0.tokenParts) }
                guard !values.isEmpty else { return TrendBucket(start: bucketStart, end: end, isComplete: true, value: nil, absoluteCount: nil) }
                let total = values.reduce(0, +)
                return TrendBucket(start: bucketStart, end: end, isComplete: true, value: Double(total) / Double(bucketSeconds) * 60, absoluteCount: total)
            })
        }
    }

    private func accessibleTable(starts: [Date], duration: TimeInterval, series: [TrendSeries], partSeries: [TrendPartSeries]) -> AccessibleTrendTable {
        if !partSeries.isEmpty {
            return AccessibleTrendTable(columnTitles: partSeries.map { $0.part.title }, rows: starts.enumerated().map { index, start in
                AccessibleTrendRow(bucketStart: start, bucketEnd: start.addingTimeInterval(duration), cells: partSeries.map { index < $0.buckets.count ? $0.buckets[index].absoluteCount.map(String.init) ?? "—" : "—" })
            })
        }
        return AccessibleTrendTable(columnTitles: series.map(\.title), rows: starts.enumerated().map { index, start in
            AccessibleTrendRow(bucketStart: start, bucketEnd: start.addingTimeInterval(duration), cells: series.map { index < $0.buckets.count ? $0.buckets[index].absoluteCount.map(String.init) ?? "—" : "—" })
        })
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
    private func partValue(_ part: TrendTokenPart, in parts: TokenParts?) -> Int? {
        switch part { case .inputUncached: parts?.inputUncached; case .cacheRead: parts?.cacheRead; case .cacheWrite: parts?.cacheWrite; case .outputVisible: parts?.outputVisible; case .reasoning: parts?.reasoning }
    }
    private func merge(parts: [TokenParts]) -> TokenParts? {
        guard !parts.isEmpty else { return nil }
        func sum(_ values: [Int?]) -> Int? { values.allSatisfy { $0 != nil } ? values.compactMap { $0 }.reduce(0, +) : nil }
        return TokenParts(inputUncached: sum(parts.map(\.inputUncached)), cacheRead: sum(parts.map(\.cacheRead)), cacheWrite: sum(parts.map(\.cacheWrite)), outputVisible: sum(parts.map(\.outputVisible)), reasoning: sum(parts.map(\.reasoning)))
    }
}

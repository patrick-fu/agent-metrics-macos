import Foundation

public enum CandidateOutcome: String, Sendable, Equatable {
    case meet = "MEET"
    case miss = "MISS"
}

public struct LatencyStatistics: Sendable, Equatable {
    public var sampleCount: Int
    public var p50Milliseconds: Double?
    public var p95Milliseconds: Double?
    public var maximumMilliseconds: Double?

    public init(samplesMilliseconds: [Double]) {
        let sorted = samplesMilliseconds.sorted()
        sampleCount = sorted.count
        p50Milliseconds = Self.nearestRank(sorted, percentile: 0.50)
        p95Milliseconds = Self.nearestRank(sorted, percentile: 0.95)
        maximumMilliseconds = sorted.last
    }

    public func outcome(candidateReferenceMilliseconds: Double) -> CandidateOutcome {
        guard let p95Milliseconds, p95Milliseconds < candidateReferenceMilliseconds else { return .miss }
        return .meet
    }

    private static func nearestRank(_ sorted: [Double], percentile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[max(0, Int(ceil(percentile * Double(sorted.count))) - 1)]
    }
}

public struct FactWindow: Sendable, Equatable {
    public var rows: [UsageFact]
    public var isTruncated: Bool
    public var truncatedSourceIDs: Set<String>
    public var retainedRange: DateInterval?

    public init(
        rows: [UsageFact],
        isTruncated: Bool,
        truncatedSourceIDs: Set<String> = []
    ) {
        self.rows = rows
        self.isTruncated = isTruncated
        self.truncatedSourceIDs = truncatedSourceIDs
        self.retainedRange = rows.first.flatMap { first in
            rows.last.map { DateInterval(start: first.observedAt, end: $0.observedAt) }
        }
    }
}

public struct PerformanceFactWindow: Sendable, Equatable {
    public var rows: [PerformanceFact]
    public var isTruncated: Bool
    public var truncatedSourceIDs: Set<String>
    public var retainedRange: DateInterval?

    public init(
        rows: [PerformanceFact],
        isTruncated: Bool,
        truncatedSourceIDs: Set<String> = []
    ) {
        self.rows = rows
        self.isTruncated = isTruncated
        self.truncatedSourceIDs = truncatedSourceIDs
        self.retainedRange = rows.first.flatMap { first in
            rows.last.map { DateInterval(start: first.observedAt, end: $0.observedAt) }
        }
    }
}

/// A source-isolated working queue. When a source reaches its cap the newly
/// arriving observation is shed; observations already accepted keep order.
public struct SourceObservationQueue: Sendable {
    public static let defaultCapacityPerSource = 256
    public static let defaultDrainLimit = 128

    private var observationsBySource: [String: [UsageObservation]] = [:]
    private var shedBySource: [String: Int] = [:]
    public let capacityPerSource: Int

    public init(capacityPerSource: Int = Self.defaultCapacityPerSource) {
        self.capacityPerSource = max(1, capacityPerSource)
    }

    @discardableResult
    public mutating func enqueue(_ observation: UsageObservation) -> Bool {
        enqueue(observation, sourceID: observation.sourceID)
    }

    @discardableResult
    public mutating func enqueue(_ observation: UsageObservation, sourceID: String) -> Bool {
        guard observationsBySource[sourceID, default: []].count < capacityPerSource else {
            shedBySource[sourceID, default: 0] += 1
            return false
        }
        observationsBySource[sourceID, default: []].append(observation)
        return true
    }

    public mutating func enqueue(contentsOf observations: [UsageObservation]) {
        for observation in observations { enqueue(observation) }
    }

    public mutating func enqueue(contentsOf observations: [UsageObservation], sourceID: String) {
        for observation in observations { enqueue(observation, sourceID: sourceID) }
    }

    public func next(sourceID: String, maximum: Int = Self.defaultDrainLimit) -> [UsageObservation] {
        guard maximum > 0 else { return [] }
        return Array(observationsBySource[sourceID, default: []].prefix(min(maximum, Self.defaultDrainLimit)))
    }

    public mutating func removeFirst(_ count: Int, sourceID: String) {
        guard count > 0, var queued = observationsBySource[sourceID] else { return }
        queued.removeFirst(min(count, queued.count))
        observationsBySource[sourceID] = queued.isEmpty ? nil : queued
    }

    public mutating func drain(
        sourceID: String,
        maximum: Int = Self.defaultDrainLimit
    ) -> [UsageObservation] {
        let drained = next(sourceID: sourceID, maximum: maximum)
        removeFirst(drained.count, sourceID: sourceID)
        return drained
    }

    public func count(for sourceID: String) -> Int {
        observationsBySource[sourceID]?.count ?? 0
    }

    public func shedCount(for sourceID: String) -> Int {
        shedBySource[sourceID, default: 0]
    }

    public mutating func resetShedCount(for sourceID: String) {
        shedBySource[sourceID] = nil
    }
}

public struct SnapshotSchedule: Sendable, Equatable {
    public var publishLight: Bool
    public var publishDetail: Bool
    public var publishDisplay: Bool

    public init(publishLight: Bool, publishDetail: Bool, publishDisplay: Bool = false) {
        self.publishLight = publishLight
        self.publishDetail = publishDetail
        self.publishDisplay = publishDisplay
    }
}

/// Deterministic cadence state. Production may drive it with a timer while
/// tests advance explicit dates, so cadence and coalescing never need sleeps.
public struct SnapshotScheduler: Sendable {
    public static let lightInterval: TimeInterval = 1
    public static let detailInterval: TimeInterval = 0.25

    public private(set) var isPopoverVisible = false
    public private(set) var displayCadence: DisplayCadence
    private var lastLightInterval: Int64?
    private var lastDetailInterval: Int64?
    private var lastDisplayInterval: Int64?

    public init(displayCadence: DisplayCadence = .default) {
        self.displayCadence = displayCadence
    }

    public mutating func setPopoverVisible(_ visible: Bool) {
        if visible && !isPopoverVisible {
            lastDetailInterval = nil
        }
        isPopoverVisible = visible
    }

    public mutating func setDisplayCadence(_ cadence: DisplayCadence) {
        displayCadence = cadence
        lastDisplayInterval = nil
    }

    public mutating func tick(at date: Date) -> SnapshotSchedule {
        let lightInterval = interval(containing: date, duration: Self.lightInterval)
        let detailInterval = interval(containing: date, duration: Self.detailInterval)
        let displayInterval = interval(containing: date, duration: displayCadence.seconds)
        let publishLight = lightInterval != lastLightInterval
        let publishDetail = isPopoverVisible && detailInterval != lastDetailInterval
        let publishDisplay = displayInterval != lastDisplayInterval
        if publishLight { lastLightInterval = lightInterval }
        if publishDetail { lastDetailInterval = detailInterval }
        if publishDisplay { lastDisplayInterval = displayInterval }
        return SnapshotSchedule(publishLight: publishLight, publishDetail: publishDetail, publishDisplay: publishDisplay)
    }

    private func interval(containing date: Date, duration: TimeInterval) -> Int64 {
        Int64(floor(date.timeIntervalSinceReferenceDate / duration))
    }
}

public final class DetailQueryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isInFlight = false

    public init() {}

    public var inFlightCount: Int {
        lock.withLock { isInFlight ? 1 : 0 }
    }

    @discardableResult
    public func begin() -> Bool {
        lock.withLock {
            guard !isInFlight else { return false }
            isInFlight = true
            return true
        }
    }

    public func end() {
        lock.withLock { isInFlight = false }
    }
}

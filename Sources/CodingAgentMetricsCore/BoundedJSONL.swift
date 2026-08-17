import Foundation

struct BoundedJSONLLine {
    var value: String?
    var endOffset: Int64
    var ordinal: Int
}

struct BoundedJSONLBatch {
    var lines: [BoundedJSONLLine]
    var consumed: Int64
    var discardingOversizedLine: Bool
    var encounteredOversizedLine: Bool
}

enum BoundedJSONL {
    /// Returns complete records only. Once a record fills an entire bounded read
    /// without a newline, later reads discard it in bounded chunks through the
    /// first newline; no fragment is ever decoded as JSON.
    static func completeLines(
        in data: Data,
        maximumBatchBytes: Int,
        discardingOversizedLine: Bool
    ) -> BoundedJSONLBatch {
        var lines: [BoundedJSONLLine] = []
        var start = data.startIndex
        var consumed = 0
        var ordinal = 0
        var discarding = discardingOversizedLine
        let encounteredOversizedLine = discardingOversizedLine

        if discarding {
            guard let newline = data[start...].firstIndex(of: 10) else {
                return BoundedJSONLBatch(
                    lines: [],
                    consumed: Int64(data.count),
                    discardingOversizedLine: true,
                    encounteredOversizedLine: true
                )
            }
            let next = data.index(after: newline)
            consumed += data.distance(from: start, to: next)
            start = next
            ordinal += 1
            discarding = false
        }

        while let newline = data[start...].firstIndex(of: 10) {
            let lineData = data[start..<newline]
            let next = data.index(after: newline)
            consumed += data.distance(from: start, to: next)
            let line = String(data: Data(lineData), encoding: .utf8)
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed?.isEmpty == false || line == nil {
                lines.append(BoundedJSONLLine(
                    value: trimmed,
                    endOffset: Int64(consumed),
                    ordinal: ordinal
                ))
            }
            start = next
            ordinal += 1
        }

        let startsWithUnterminatedFullBatch = consumed == 0
            && data.count == maximumBatchBytes
        if startsWithUnterminatedFullBatch {
            return BoundedJSONLBatch(
                lines: [],
                consumed: Int64(data.count),
                discardingOversizedLine: true,
                encounteredOversizedLine: true
            )
        }

        return BoundedJSONLBatch(
            lines: lines,
            consumed: Int64(consumed),
            discardingOversizedLine: discarding,
            encounteredOversizedLine: encounteredOversizedLine
        )
    }
}

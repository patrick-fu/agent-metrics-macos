import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct AccessibleTrendTableCursorTests {
    @Test func announcementGuardsEmptyTablesAndClampsWhenColumnsShrink() {
        var cursor = AccessibleTrendTableCursor(rowIndex: 3, columnIndex: 4)
        let empty = AccessibleTrendTable(columnTitles: [], rows: [])
        cursor.clamp(to: empty)
        #expect(cursor.rowIndex == 0)
        #expect(cursor.columnIndex == 0)
        #expect(cursor.announcement(in: empty).contains("No trend values"))

        let burn = table(
            titles: ["Input uncached", "Cache read", "Cache write", "Output visible", "Reasoning"],
            identities: ["Input uncached", "Cache read", "Cache write", "Output visible", "Reasoning"],
            cells: [["10", "20", "30", "40", "50"]]
        )
        cursor = AccessibleTrendTableCursor(rowIndex: 0, columnIndex: 4)
        #expect(cursor.announcement(in: burn).contains("50"))

        let calls = table(titles: ["Calls"], identities: ["calls"], cells: [["2"]])
        cursor.clamp(to: calls)
        #expect(cursor.rowIndex == 0)
        #expect(cursor.columnIndex == 0)
        let spoken = cursor.announcement(in: calls)
        #expect(spoken.contains("Calls"))
        #expect(spoken.contains("2"))
        #expect(!spoken.contains("50"))
    }

    @Test func announcementLocksUTCBucketBoundsAndCellCopy() {
        let start = Date(timeIntervalSince1970: 1_771_200)
        let end = Date(timeIntervalSince1970: 1_771_230)
        let table = table(
            titles: ["Opus (opus-b)"],
            identities: ["opus-b"],
            cells: [["20"]],
            start: start,
            end: end
        )
        let cursor = AccessibleTrendTableCursor()
        let spoken = cursor.announcement(in: table)
        #expect(spoken.contains("1970-01-21T12:00:00Z"))
        #expect(spoken.contains("1970-01-21T12:00:30Z"))
        #expect(spoken.contains("Opus (opus-b)"))
        #expect(spoken.contains("opus-b"))
        #expect(spoken.contains("20"))
        #expect(spoken.contains("Quality Derived"))
        #expect(spoken.contains("Coverage Complete"))

        let cell = cursor.cellAccessibility(in: table)
        #expect(cell.label.contains("1970-01-21T12:00:00Z"))
        #expect(cell.label.contains("1970-01-21T12:00:30Z"))
        #expect(cell.label.contains("Opus (opus-b)"))
        #expect(cell.label.contains("opus-b"))
        #expect(cell.value.contains("20"))
        #expect(cell.value.contains("Quality Derived"))
        #expect(cell.value.contains("State -"))
        #expect(cell.value.contains("Coverage Complete"))
    }

    private func table(
        titles: [String],
        identities: [String],
        cells: [[String]],
        start: Date = Date(timeIntervalSince1970: 1_771_200),
        end: Date = Date(timeIntervalSince1970: 1_771_230)
    ) -> AccessibleTrendTable {
        AccessibleTrendTable(
            columnTitles: titles,
            rows: cells.map { AccessibleTrendRow(bucketStart: start, bucketEnd: end, cells: $0) },
            columns: zip(titles, identities).map {
                AccessibleTrendColumn(title: $0.0, identityLabel: $0.1, emphasisText: "Exact", symbol: "●")
            },
            qualityText: "Derived",
            dataStateText: "-",
            coverageText: "Complete"
        )
    }
}

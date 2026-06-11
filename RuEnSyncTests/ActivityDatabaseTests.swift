import Foundation
@testable import RuEnSync
import Testing

@MainActor
struct ActivityDatabaseTests {
    @Test("insert adds entry to database")
    func insertWorks() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let entry = ActivityEntry(kind: .layoutChanged(label: "RU"))
        try db.insert(entry)

        #expect(db.count() == 1)

        let loaded = db.loadRecent(limit: 1)
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == entry.id)
        #expect(loaded.first?.kind == .layoutChanged(label: "RU"))
    }

    @Test("inserting multiple entries increments count")
    func insertMultiple() throws {
        let db = try ActivityDatabase(path: ":memory:")
        try db.insert(ActivityEntry(kind: .deviceConnected(name: "Corne")))
        try db.insert(ActivityEntry(kind: .layoutChanged(label: "EN")))
        try db.insert(ActivityEntry(kind: .deviceDisconnected(name: "Corne", reason: "Unplugged")))

        #expect(db.count() == 3)
    }

    @Test("insert replaces entry with same ID")
    func insertReplacesSameID() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let id = UUID()
        let firstEntry = ActivityEntry(id: id, timestamp: Date(), kind: .layoutChanged(label: "EN"))
        try db.insert(firstEntry)

        #expect(db.count() == 1)

        // Insert again with the same ID but a different label
        let secondEntry = ActivityEntry(
            id: id,
            timestamp: Date().addingTimeInterval(10),
            kind: .layoutChanged(label: "RU")
        )
        try db.insert(secondEntry)

        // Count should still be 1
        #expect(db.count() == 1)

        let loaded = db.loadRecent(limit: 1)
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == id)
        #expect(loaded.first?.kind == .layoutChanged(label: "RU"))
    }
}

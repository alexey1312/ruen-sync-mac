@testable import RuEnSync
import Testing

@MainActor
struct ActivityStoreTests {
    @Test("new store with empty in-memory DB has zero entries")
    func emptyInit() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let store = ActivityStore(database: db)
        #expect(store.entries.isEmpty)
    }

    @Test("record inserts newest-first")
    func recordOrder() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let store = ActivityStore(database: db)
        store.record(.layoutChanged(label: "EN"))
        store.record(.layoutChanged(label: "RU"))
        #expect(store.entries.count == 2)
        if case let .layoutChanged(label) = store.entries[0].kind {
            #expect(label == "RU")
        } else {
            Issue.record("expected layoutChanged at index 0")
        }
    }

    @Test("ring buffer caps at capacity, dropping oldest from the mirror")
    func ringBufferTrim() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let store = ActivityStore(capacity: 3, database: db)
        store.record(.layoutChanged(label: "A"))
        store.record(.layoutChanged(label: "B"))
        store.record(.layoutChanged(label: "C"))
        store.record(.layoutChanged(label: "D"))
        #expect(store.entries.count == 3)
        // Newest first: D, C, B. A fell off the in-memory tail.
        if case let .layoutChanged(label) = store.entries[0].kind { #expect(label == "D") }
        if case let .layoutChanged(label) = store.entries[2].kind { #expect(label == "B") }
        // DB still has all 4 — only the in-memory mirror is bounded.
        #expect(db.count() == 4)
    }

    @Test("clear empties both the mirror and the DB")
    func clear() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let store = ActivityStore(database: db)
        store.record(.reconnectTriggered)
        store.record(.deviceConnected(name: "Corne"))
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(db.count() == 0)
    }

    @Test("store rehydrates from DB across init")
    func rehydrate() throws {
        // Share one DB connection between two store instances — mirrors what
        // happens between launches in production, just without the file step.
        let db = try ActivityDatabase(path: ":memory:")
        let first = ActivityStore(database: db)
        first.record(.layoutChanged(label: "EN"))
        first.record(.deviceConnected(name: "Corne"))
        first.record(.osHandshakeSent(name: "Corne"))

        let second = ActivityStore(database: db)
        #expect(second.entries.count == 3)
        // Newest-first ordering must survive the round-trip.
        if case let .osHandshakeSent(name) = second.entries[0].kind {
            #expect(name == "Corne")
        } else {
            Issue.record("expected osHandshakeSent at index 0 after rehydrate")
        }
    }

    @Test("rehydrate respects capacity cap on the mirror")
    func rehydrateCapacity() throws {
        let db = try ActivityDatabase(path: ":memory:")
        let producer = ActivityStore(capacity: 100, database: db)
        for label in ["A", "B", "C", "D", "E"] {
            producer.record(.layoutChanged(label: label))
        }
        let consumer = ActivityStore(capacity: 3, database: db)
        #expect(consumer.entries.count == 3)
        if case let .layoutChanged(label) = consumer.entries[0].kind { #expect(label == "E") }
        if case let .layoutChanged(label) = consumer.entries[2].kind { #expect(label == "C") }
    }
}

struct ActivityKindTests {
    @Test("layoutChanged headline shows the new label")
    func layoutHeadline() {
        #expect(ActivityKind.layoutChanged(label: "RU").headline == "Layout → RU")
    }

    @Test("disconnected headline includes the reason")
    func disconnectedHeadline() {
        let kind = ActivityKind.deviceDisconnected(name: "Corne", reason: "Device busy (qmk-hid-host running?)")
        #expect(kind.headline.contains("Corne"))
        #expect(kind.headline.contains("qmk-hid-host"))
    }

    @Test("each kind has a non-empty symbol")
    func symbolsExist() {
        let kinds: [ActivityKind] = [
            .layoutChanged(label: "EN"),
            .deviceConnected(name: "x"),
            .deviceDisconnected(name: "x", reason: "y"),
            .deviceOfflineReasonChanged(name: "x", reason: "y"),
            .osHandshakeSent(name: "x"),
            .osHandshakeFailed(name: "x"),
            .reconnectTriggered,
            .yieldedToApp(name: "Vial"),
            .resumedAfterApp(name: "Vial"),
        ]
        for kind in kinds {
            #expect(!kind.symbol.isEmpty)
        }
    }

    @Test("yield/resume headlines include the app name")
    func yieldHeadlines() {
        #expect(ActivityKind.yieldedToApp(name: "Vial").headline == "Yielded to Vial")
        #expect(ActivityKind.resumedAfterApp(name: "Vial").headline == "Resumed after Vial")
    }

    @Test("storable round-trips for every kind")
    func storableRoundTrip() {
        let kinds: [ActivityKind] = [
            .layoutChanged(label: "EN"),
            .deviceConnected(name: "Corne"),
            .deviceDisconnected(name: "Corne", reason: "busy"),
            .deviceOfflineReasonChanged(name: "Corne", reason: "open failed"),
            .osHandshakeSent(name: "Corne"),
            .osHandshakeFailed(name: "Corne"),
            .reconnectTriggered,
            .yieldedToApp(name: "Vial"),
            .resumedAfterApp(name: "QMK Toolbox"),
        ]
        for kind in kinds {
            let s = kind.storable
            let rebuilt = ActivityKind(
                discriminator: s.discriminator,
                deviceName: s.deviceName,
                reason: s.reason,
                label: s.label
            )
            #expect(rebuilt == kind)
        }
    }

    @Test("unknown discriminator is rejected, not crash")
    func unknownDiscriminator() {
        #expect(
            ActivityKind(
                discriminator: "newFromFutureBuild",
                deviceName: nil,
                reason: nil,
                label: nil
            ) == nil
        )
    }
}

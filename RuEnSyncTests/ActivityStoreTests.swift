@testable import RuEnSync
import Testing

@MainActor
struct ActivityStoreTests {
    @Test("new store has zero entries")
    func emptyInit() {
        let store = ActivityStore()
        #expect(store.entries.isEmpty)
    }

    @Test("record inserts newest-first")
    func recordOrder() {
        let store = ActivityStore()
        store.record(.layoutChanged(label: "EN"))
        store.record(.layoutChanged(label: "RU"))
        #expect(store.entries.count == 2)
        if case let .layoutChanged(label) = store.entries[0].kind {
            #expect(label == "RU")
        } else {
            Issue.record("expected layoutChanged at index 0")
        }
    }

    @Test("ring buffer caps at capacity, dropping oldest")
    func ringBufferTrim() {
        let store = ActivityStore(capacity: 3)
        store.record(.layoutChanged(label: "A"))
        store.record(.layoutChanged(label: "B"))
        store.record(.layoutChanged(label: "C"))
        store.record(.layoutChanged(label: "D"))
        #expect(store.entries.count == 3)
        // Newest first: D, C, B. A fell off the back.
        if case let .layoutChanged(label) = store.entries[0].kind { #expect(label == "D") }
        if case let .layoutChanged(label) = store.entries[2].kind { #expect(label == "B") }
    }

    @Test("clear empties the buffer")
    func clear() {
        let store = ActivityStore()
        store.record(.reconnectTriggered)
        store.clear()
        #expect(store.entries.isEmpty)
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
        ]
        for kind in kinds {
            #expect(!kind.symbol.isEmpty)
        }
    }
}

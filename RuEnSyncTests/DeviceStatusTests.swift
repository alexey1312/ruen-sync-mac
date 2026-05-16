@testable import RuEnSync
import Testing

struct DeviceStatusTests {
    private func status(state: HIDLink.State, name: String = "Corne", id: Int = 0) -> AppModel.DeviceStatus {
        AppModel.DeviceStatus(id: id, name: name, productId: 0x0001, state: state)
    }

    @Test("connected summary uses 'connected'")
    func connectedSummary() {
        let row = status(state: .connected(productId: 0x0001))
        #expect(row.summary == "Corne — connected")
    }

    @Test("offline-awaiting summary uses lowercase 'not connected'")
    func awaitingSummary() {
        let row = status(state: .offline(reason: .awaitingDevice))
        #expect(row.summary == "Corne — not connected")
    }

    @Test("offline-exclusiveAccess summary mentions qmk-hid-host")
    func exclusiveSummary() {
        let row = status(state: .offline(reason: .exclusiveAccess))
        #expect(row.summary.lowercased().contains("qmk-hid-host"))
        #expect(row.summary.hasPrefix("Corne —"))
    }

    @Test("offline-openFailed summary contains hex code")
    func openFailedSummary() {
        let row = status(state: .offline(reason: .openFailed(code: Int32(bitPattern: 0xE000_02BC))))
        #expect(row.summary.contains("0xE00002BC"))
    }

    @Test("productIdLabel is zero-padded 4-digit hex")
    func productIdLabel() {
        let row = AppModel.DeviceStatus(id: 0, name: "x", productId: 0x0001, state: .offline(reason: .awaitingDevice))
        #expect(row.productIdLabel == "0x0001")

        let high = AppModel.DeviceStatus(id: 0, name: "x", productId: 0xFFFF, state: .offline(reason: .awaitingDevice))
        #expect(high.productIdLabel == "0xFFFF")
    }
}

@MainActor
struct AppModelDescribeTests {
    private func status(_ state: HIDLink.State, name: String = "Corne", id: Int = 0) -> AppModel.DeviceStatus {
        AppModel.DeviceStatus(id: id, name: name, productId: 0x0001, state: state)
    }

    @Test("empty config reports 'no device configured'")
    func emptyDescribe() {
        #expect(AppModel.describe([]) == "No device configured")
    }

    @Test("single device delegates to its summary")
    func singleDeviceDescribe() {
        let only = status(.connected(productId: 0x0001))
        #expect(AppModel.describe([only]) == only.summary)
    }

    @Test("multi-device renders 'X of N connected' — all offline")
    func multiOffline() {
        let statuses = [
            status(.offline(reason: .awaitingDevice), name: "A", id: 0),
            status(.offline(reason: .awaitingDevice), name: "B", id: 1),
        ]
        #expect(AppModel.describe(statuses) == "0 of 2 connected")
    }

    @Test("multi-device 'X of N connected' counts only connected entries")
    func multiMixed() {
        let statuses = [
            status(.connected(productId: 1), name: "A", id: 0),
            status(.offline(reason: .exclusiveAccess), name: "B", id: 1),
            status(.connected(productId: 3), name: "C", id: 2),
        ]
        #expect(AppModel.describe(statuses) == "2 of 3 connected")
    }

    @Test("multi-device all connected → N of N")
    func multiAllConnected() {
        let statuses = [
            status(.connected(productId: 1), name: "A", id: 0),
            status(.connected(productId: 2), name: "B", id: 1),
        ]
        #expect(AppModel.describe(statuses) == "2 of 2 connected")
    }
}

struct LowercasedFirstLetterTests {
    @Test("empty string stays empty")
    func empty() {
        #expect("".lowercasedFirstLetter().isEmpty)
    }

    @Test("single uppercase becomes lowercase")
    func singleChar() {
        #expect("A".lowercasedFirstLetter() == "a")
    }

    @Test("'Not connected' → 'not connected'")
    func sentence() {
        #expect("Not connected".lowercasedFirstLetter() == "not connected")
    }

    @Test("Cyrillic first letter is lowercased correctly")
    func cyrillic() {
        #expect("Привет".lowercasedFirstLetter() == "привет")
    }
}

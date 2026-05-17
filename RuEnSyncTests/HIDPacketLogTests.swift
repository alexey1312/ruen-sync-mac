@testable import RuEnSync
import Testing

@MainActor
struct HIDPacketLogTests {
    @Test("interpret labels 0xAC layout packets with EN/RU")
    func interpretLayout() {
        var en = [UInt8](repeating: 0, count: 32)
        en[0] = 0xAC; en[1] = 0
        var ru = [UInt8](repeating: 0, count: 32)
        ru[0] = 0xAC; ru[1] = 1
        #expect(HIDPacketEntry.interpret(en).contains("EN"))
        #expect(HIDPacketEntry.interpret(ru).contains("RU"))
    }

    @Test("interpret labels 0xB0 OS handshake with the magic suffix")
    func interpretOSHandshake() {
        var pkt = [UInt8](repeating: 0, count: 32)
        pkt[0] = 0xB0; pkt[1] = 0x4D; pkt[2] = 0x41; pkt[3] = 0x43
        let label = HIDPacketEntry.interpret(pkt)
        #expect(label.contains("OS handshake"))
        #expect(label.contains("MAC"))
    }

    @Test("interpret surfaces unknown data_type bytes instead of guessing")
    func interpretUnknown() {
        var pkt = [UInt8](repeating: 0, count: 32)
        pkt[0] = 0xC9
        let label = HIDPacketEntry.interpret(pkt)
        // Future protocol bytes must NOT be silently labelled "layout" —
        // surface them explicitly so the inspector tells us "unknown".
        #expect(label.contains("0xC9"))
        #expect(label.contains("unknown"))
    }

    @Test("ring buffer drops oldest beyond capacity")
    func ringBufferDrop() {
        let log = HIDPacketLog(capacity: 3)
        for i in 0..<5 {
            var bytes = [UInt8](repeating: 0, count: 32)
            bytes[0] = 0xAC
            bytes[1] = UInt8(i)
            log.record(deviceName: "Test", productId: 0x0001, bytes: bytes)
        }
        #expect(log.entries.count == 3)
        // Newest first: idx 4, 3, 2.
        #expect(log.entries[0].bytes[1] == 4)
        #expect(log.entries[2].bytes[1] == 2)
    }
}

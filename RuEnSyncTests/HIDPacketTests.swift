@testable import RuEnSync
import Testing

@Suite("HID wire format")
struct HIDPacketTests {
    @Test("report is 33 bytes long")
    func reportLength() {
        let report = HIDLink.buildReport(layoutIndex: 0)
        #expect(report.count == 33)
    }

    @Test("byte 0 is the report ID (0x00)")
    func reportIDPrefix() {
        let report = HIDLink.buildReport(layoutIndex: 1)
        #expect(report[0] == 0x00)
    }

    @Test("byte 1 is _LAYOUT data type (0xAC)")
    func layoutDataType() {
        let report = HIDLink.buildReport(layoutIndex: 0)
        #expect(report[1] == 0xAC)
    }

    @Test("byte 2 is the layout index — 0 for EN")
    func enIndex() {
        let report = HIDLink.buildReport(layoutIndex: 0)
        #expect(report[2] == 0x00)
    }

    @Test("byte 2 is the layout index — non-zero for RU")
    func ruIndex() {
        let report = HIDLink.buildReport(layoutIndex: 1)
        #expect(report[2] == 0x01)
    }

    @Test("remaining 30 bytes are zero-padded")
    func zeroPadded() {
        let report = HIDLink.buildReport(layoutIndex: 42)
        for byte in report[3...] {
            #expect(byte == 0)
        }
    }
}

@testable import RuEnSync
import Testing

struct HIDPacketTests {
    @Test("report is 32 bytes long (QMK RAW_EPSIZE)")
    func reportLength() {
        let report = HIDLink.buildReport(layoutIndex: 0)
        #expect(report.count == 32)
    }

    @Test("byte 0 is _LAYOUT data type (0xAC) — firmware parses data[0]")
    func layoutDataType() {
        let report = HIDLink.buildReport(layoutIndex: 0)
        #expect(report[0] == 0xAC)
    }

    @Test("byte 1 is the layout index — 0 for EN")
    func enIndex() {
        let report = HIDLink.buildReport(layoutIndex: 0)
        #expect(report[1] == 0x00)
    }

    @Test("byte 1 is the layout index — non-zero for RU")
    func ruIndex() {
        let report = HIDLink.buildReport(layoutIndex: 1)
        #expect(report[1] == 0x01)
    }

    @Test("remaining 30 bytes are zero-padded")
    func zeroPadded() {
        let report = HIDLink.buildReport(layoutIndex: 42)
        for byte in report[2...] {
            #expect(byte == 0)
        }
    }

    // MARK: - _OS_TYPE packet

    @Test("OS report is also 32 bytes")
    func osReportLength() {
        let report = HIDLink.buildOSReport()
        #expect(report.count == 32)
    }

    @Test("OS report byte 0 is _OS_TYPE data type (0xB0)")
    func osDataType() {
        let report = HIDLink.buildOSReport()
        #expect(report[0] == 0xB0)
    }

    @Test("OS report carries MAC\\0 magic at offsets 1..4")
    func osMagic() {
        let report = HIDLink.buildOSReport()
        #expect(report[1] == 0x4D) // 'M'
        #expect(report[2] == 0x41) // 'A'
        #expect(report[3] == 0x43) // 'C'
        #expect(report[4] == 0x00) // NUL — magic borrowed from nomis/qmk-hid-identify (not its full wire format)
    }

    @Test("OS report — bytes after the magic are zero-padded")
    func osZeroPadded() {
        let report = HIDLink.buildOSReport()
        for byte in report[5...] {
            #expect(byte == 0)
        }
    }
}

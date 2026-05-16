@testable import RuEnSync
import Testing

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

    // MARK: - _OS_TYPE packet

    @Test("OS report is also 33 bytes")
    func osReportLength() {
        let report = HIDLink.buildOSReport()
        #expect(report.count == 33)
    }

    @Test("OS report byte 0 is the report ID (0x00)")
    func osReportPrefix() {
        let report = HIDLink.buildOSReport()
        #expect(report[0] == 0x00)
    }

    @Test("OS report byte 1 is _OS_TYPE data type (0xB0)")
    func osDataType() {
        let report = HIDLink.buildOSReport()
        #expect(report[1] == 0xB0)
    }

    @Test("OS report carries MAC\\0 magic at offsets 2..5")
    func osMagic() {
        let report = HIDLink.buildOSReport()
        #expect(report[2] == 0x4D) // 'M'
        #expect(report[3] == 0x41) // 'A'
        #expect(report[4] == 0x43) // 'C'
        #expect(report[5] == 0x00) // NUL — matches nomis/qmk-hid-identify wire format
    }

    @Test("OS report — bytes after the magic are zero-padded")
    func osZeroPadded() {
        let report = HIDLink.buildOSReport()
        for byte in report[6...] {
            #expect(byte == 0)
        }
    }
}

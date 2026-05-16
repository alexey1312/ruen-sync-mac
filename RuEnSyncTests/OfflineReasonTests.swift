@testable import RuEnSync
import Testing

struct OfflineReasonTests {
    @Test("awaitingDevice menuLabel is non-empty and user-friendly")
    func awaitingDeviceLabel() {
        let label = HIDLink.OfflineReason.awaitingDevice.menuLabel
        #expect(!label.isEmpty)
        #expect(label == "Not connected")
    }

    @Test("exclusiveAccess label nudges the user toward qmk-hid-host")
    func exclusiveAccessLabel() {
        // The whole reason this case exists is so the user knows to kill the
        // conflicting daemon. Asserting on the hint instead of the exact
        // wording — wording can change, the hint must not disappear.
        let label = HIDLink.OfflineReason.exclusiveAccess.menuLabel
        #expect(label.contains("qmk-hid-host"))
    }

    @Test("openFailed label includes the hex IOReturn code")
    func openFailedLabel() {
        let label = HIDLink.OfflineReason.openFailed(code: Int32(bitPattern: 0xE000_02BC)).menuLabel
        #expect(label.contains("0xE00002BC"))
    }

    @Test("managerOpenFailed label includes the hex IOReturn code")
    func managerOpenFailedLabel() {
        let label = HIDLink.OfflineReason.managerOpenFailed(code: Int32(bitPattern: 0xE000_02C2)).menuLabel
        #expect(label.contains("0xE00002C2"))
    }

    @Test("openFailed and managerOpenFailed labels are distinguishable")
    func failureCasesAreDistinguishable() {
        let open = HIDLink.OfflineReason.openFailed(code: 1).menuLabel
        let manager = HIDLink.OfflineReason.managerOpenFailed(code: 1).menuLabel
        #expect(open != manager)
    }

    @Test("OS magic byte choice is forward of qmk-hid-host's allocation")
    func osTypeDataTypeIsSafelyFree() {
        // qmk-hid-host's macOS build uses up to 0xAF (Weather); Linux uses
        // 0xAE (MediaTitle). We must stay > 0xAF to avoid collision.
        #expect(HIDLink.osTypeDataType > 0xAF)
    }
}

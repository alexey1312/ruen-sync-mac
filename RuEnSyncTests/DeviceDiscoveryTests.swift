@testable import RuEnSync
import Testing

@MainActor
struct DeviceDiscoveryTests {
    @Test("scan returns a (possibly empty) array without crashing")
    func scanIsCallable() {
        // We can't assert *content* here — the test environment doesn't
        // have a QMK keyboard plugged in, and CI definitely doesn't.
        // The point is that the IOHIDManager dance is well-formed: no
        // matching-dict typos, no force-unwraps on missing properties,
        // sorts deterministically. Returning an empty array is a valid
        // result and must not throw / crash.
        let result = DeviceDiscovery.scan()
        // Two consecutive scans must agree — the only thing that changes
        // is the underlying hardware state. On a CI box that's nothing.
        let result2 = DeviceDiscovery.scan()
        #expect(result.map(\.productId) == result2.map(\.productId))
    }

    @Test("displayName falls back to product id when nothing else is set")
    func displayNameFallback() {
        let device = DiscoveredDevice(
            productId: 0x0042,
            vendorId: 0,
            manufacturer: nil,
            productName: nil,
            uniqueId: 1
        )
        #expect(device.displayName.contains("0042"))
    }

    @Test("displayName prefers productName over manufacturer")
    func displayNamePrefersProductName() {
        let device = DiscoveredDevice(
            productId: 0x0001,
            vendorId: 0xFEED,
            manufacturer: "FOSTAR",
            productName: "crkbd",
            uniqueId: 1
        )
        #expect(device.displayName == "crkbd")
    }
}

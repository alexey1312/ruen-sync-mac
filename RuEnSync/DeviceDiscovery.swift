import Foundation
import IOKit
import IOKit.hid

// MARK: - DiscoveredDevice

/// One QMK Raw HID interface visible to IOKit right now. Captures just
/// enough to identify and label the device in a picker — `productId` is
/// the only field RuEnSync actually needs to start syncing.
struct DiscoveredDevice: Equatable, Identifiable {
    /// `productId` as a stable identity; if two identical keyboards are
    /// plugged in we deduplicate by IOKit registry entry id (`uniqueId`).
    /// For most users it's a one-to-one mapping.
    var id: UInt64 { uniqueId }
    let productId: UInt32
    let vendorId: UInt32
    /// `kIOHIDManufacturerKey` — e.g. "QMK", "FOSTAR".
    let manufacturer: String?
    /// `kIOHIDProductKey` — e.g. "crkbd", "Lily58".
    let productName: String?
    /// IOKit registry entry id. Unique per physical-port-per-boot, so a
    /// matched pair of identical keyboards still gets two distinct rows.
    let uniqueId: UInt64

    /// A friendly label for the picker, falling back gracefully if the
    /// device doesn't expose nice metadata.
    var displayName: String {
        if let productName, !productName.isEmpty { return productName }
        if let manufacturer, !manufacturer.isEmpty { return manufacturer }
        return String(format: "Device 0x%04X", productId)
    }

    var productIdHex: String {
        String(format: "0x%04X", productId)
    }
}

// MARK: - DeviceDiscovery

/// One-shot scanner that snapshots all currently-connected QMK Raw HID
/// interfaces (`usagePage = 0xFF60`, `usage = 0x61`). Doesn't open the
/// devices — read-only inspection. Safe to call repeatedly; the Settings
/// "Scan…" button re-runs it on demand.
///
/// Implementation: build a transient `IOHIDManager` with the QMK matching
/// dict, ask for `IOHIDManagerCopyDevices`, read the properties we care
/// about, tear the manager down. We do NOT call `IOHIDManagerOpen` —
/// that would race the live `HIDLink` for exclusive access. Property
/// access works without opening.
enum DeviceDiscovery {
    static func scan() -> [DiscoveredDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: NSNumber(value: ResolvedDevice.qmkUsagePage),
            kIOHIDPrimaryUsageKey: NSNumber(value: ResolvedDevice.qmkUsage),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devicesSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            Log.hid.info("device discovery: IOHIDManagerCopyDevices returned no devices")
            return []
        }

        var found: [DiscoveredDevice] = []
        for device in devicesSet {
            guard let entry = makeEntry(from: device) else { continue }
            found.append(entry)
        }
        // Stable order makes the picker deterministic across rescans.
        return found.sorted { lhs, rhs in
            if lhs.productId != rhs.productId { return lhs.productId < rhs.productId }
            return lhs.uniqueId < rhs.uniqueId
        }
    }

    private static func makeEntry(from device: IOHIDDevice) -> DiscoveredDevice? {
        guard let productId = readUInt32(device, key: kIOHIDProductIDKey) else { return nil }
        let vendorId = readUInt32(device, key: kIOHIDVendorIDKey) ?? 0
        let manufacturer = readString(device, key: kIOHIDManufacturerKey)
        let productName = readString(device, key: kIOHIDProductKey)
        let uniqueId = readUInt64(device, key: kIOHIDLocationIDKey) ?? UInt64(productId)
        return DiscoveredDevice(
            productId: productId,
            vendorId: vendorId,
            manufacturer: manufacturer,
            productName: productName,
            uniqueId: uniqueId
        )
    }

    private static func readUInt32(_ device: IOHIDDevice, key: String) -> UInt32? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        if let number = raw as? NSNumber { return number.uint32Value }
        return nil
    }

    private static func readUInt64(_ device: IOHIDDevice, key: String) -> UInt64? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        if let number = raw as? NSNumber { return number.uint64Value }
        return nil
    }

    private static func readString(_ device: IOHIDDevice, key: String) -> String? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return raw as? String
    }
}

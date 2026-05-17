import Foundation
import Observation

// MARK: - HIDPacketEntry

/// One row in the HID Inspector. Immutable. Captures every byte of the
/// 32-byte report so we can show a faithful hex dump — interpretation is a
/// derived human-readable summary, not a substitute for the raw bytes.
struct HIDPacketEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    /// Friendly device label, e.g. `"Corne"`. Matches `Config.Device.name`.
    let deviceName: String
    /// HID product id (`kIOHIDProductIDKey`), e.g. `0x0001`.
    let productId: UInt32
    /// All 32 bytes of the report. Length is always
    /// `HIDLink.reportSize` (32) but we don't enforce at the type level —
    /// the inspector renders whatever we get to surface protocol drift.
    let bytes: [UInt8]
    /// Human-readable interpretation derived from `bytes[0]` (data-type byte).
    /// See `HIDPacketEntry.interpret(_:)` for the data-type → text mapping.
    let interpretation: String

    init(id: UUID = UUID(), timestamp: Date = Date(), deviceName: String, productId: UInt32, bytes: [UInt8]) {
        self.id = id
        self.timestamp = timestamp
        self.deviceName = deviceName
        self.productId = productId
        self.bytes = bytes
        self.interpretation = Self.interpret(bytes)
    }

    /// Pure mapping from packet bytes to a one-line label. Lives next to the
    /// type so it stays in sync with new data-types added to the protocol.
    /// Returns `"unknown data_type 0xXX"` for bytes we don't recognise so a
    /// future firmware adding `0xB1` etc. surfaces in the inspector
    /// immediately rather than being silently labelled "layout".
    static func interpret(_ bytes: [UInt8]) -> String {
        guard let dataType = bytes.first else { return "empty packet" }
        switch dataType {
        case 0xAC:
            let idx = bytes.dropFirst().first ?? 0
            return "layout \(idx == 0 ? "EN" : "RU") (idx=\(idx))"
        case 0xB0:
            // _OS_TYPE — 4-byte ASCII OS magic at bytes[1..5].
            let magic = String(bytes: Array(bytes.dropFirst().prefix(3)), encoding: .ascii) ?? "?"
            return "OS handshake \"\(magic)\""
        default:
            return String(format: "unknown data_type 0x%02X", dataType)
        }
    }
}

// MARK: - HIDPacketLog

/// Ring-buffer of recent HID writes for the Debug → HID Inspector window.
/// Capacity bound keeps SwiftUI updates cheap even on a chatty session.
///
/// Writes are gated by an external flag (`Config.debug?.hidInspector`) so
/// the production HIDLink path stays allocation-free when the inspector
/// isn't being used — see `HIDLink.send` callsites.
@MainActor
@Observable
final class HIDPacketLog {
    /// Newest first.
    private(set) var entries: [HIDPacketEntry] = []
    let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func record(deviceName: String, productId: UInt32, bytes: [UInt8]) {
        let entry = HIDPacketEntry(deviceName: deviceName, productId: productId, bytes: bytes)
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

import SwiftUI

// MARK: - HIDInspectorView

/// Debug window listing recent HID writes. Hex dump + interpretation per row.
/// Re-renders only when `packetLog.entries` changes — the `@Bindable` macro
/// from Observation makes the @Observable class observable in SwiftUI without
/// `@StateObject` or `@ObservedObject`.
struct HIDInspectorView: View {
    @Bindable var packetLog: HIDPacketLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if packetLog.entries.isEmpty {
                emptyState
            } else {
                List(packetLog.entries) { entry in
                    PacketRow(entry: entry)
                }
                .listStyle(.plain)
                .frame(minWidth: 540, minHeight: 320)
            }
        }
        .frame(minWidth: 540, minHeight: 360)
    }

    private var header: some View {
        HStack {
            Text("HID Inspector")
                .font(.headline)
            Spacer()
            Text("\(packetLog.entries.count) / \(packetLog.capacity)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Clear") {
                packetLog.clear()
            }
            .disabled(packetLog.entries.isEmpty)
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("No packets recorded yet.")
                .font(.body)
            Text("Enable inspection in config.json:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(#"  "debug": { "hidInspector": true }"#)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Row

private struct PacketRow: View {
    let entry: HIDPacketEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.deviceName)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                Text(productLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.interpretation)
                .font(.caption)
                .foregroundStyle(.primary)
            Text(hexDump)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var productLabel: String {
        String(format: "pid=0x%04X", entry.productId)
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: entry.timestamp)
    }

    /// Two-line hex dump: 16 bytes per row, mirrors `hexdump -C` style minus
    /// the offset column. Easier to spot the data-type byte at offset 0 and
    /// the layout idx at offset 1.
    private var hexDump: String {
        let half = entry.bytes.prefix(16)
        let rest = entry.bytes.dropFirst(16).prefix(16)
        func format(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        return format(Array(half)) + "\n" + format(Array(rest))
    }
}

import AppKit
import SwiftUI

// MARK: - HIDInspectorView

/// Debug window listing recent HID writes. Hex dump + interpretation per row.
/// Re-renders only when `packetLog.entries` changes — the `@Bindable` macro
/// from Observation makes the @Observable class observable in SwiftUI without
/// `@StateObject` or `@ObservedObject`.
///
/// The window stays above other apps (`NSWindow.Level.floating`) so users
/// can keep it visible while testing keyboard sync in another app —
/// otherwise switching focus to Notes/Xcode hides the inspector and
/// defeats the point of watching live packets.
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
        .background(
            // NSViewRepresentable hop to reach the hosting NSWindow.
            // SwiftUI's WindowGroup doesn't expose `level` declaratively
            // before macOS 15, so we set it on first appearance.
            WindowConfigurator { window in
                window.level = .floating
                window.collectionBehavior.insert(.canJoinAllSpaces)
            }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("HID Inspector")
                    .font(.headline)
                Text("Live capture of outgoing 32-byte reports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Capacity meter rendered as "used / cap" with a tiny progress
            // bar so the user sees the ring buffer filling up rather than
            // staring at a flat number.
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(packetLog.entries.count) / \(packetLog.capacity)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(packetLog.entries.count), total: Double(max(packetLog.capacity, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .controlSize(.mini)
            }
            Button {
                packetLog.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(packetLog.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No packets recorded yet")
                .font(.headline)
            Text("Toggle *Settings → Debug → Record HID writes* on, then trigger a layout switch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(#"or set "debug": { "hidInspector": true } in config.json"#)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - WindowConfigurator

/// SwiftUI ↔ AppKit bridge: gets a callback once the hosting NSWindow exists
/// so we can tweak properties (level, collectionBehavior) that aren't yet
/// surfaced as SwiftUI modifiers. The async hop is necessary because
/// `makeNSView` runs before the view is mounted into a window.
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Row

private struct PacketRow: View {
    let entry: HIDPacketEntry

    /// Cached formatter — `DateFormatter` allocation is ~tens of µs and
    /// keeps the per-row cost flat regardless of how many packets the
    /// inspector is rendering. Static so every PacketRow instance shares
    /// the same configured formatter.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Pure static formatter — exposed for testability and so the row's
    /// `timestamp` computed property stays a one-liner.
    static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dataTypeBadge

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
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
        }
        .padding(.vertical, 6)
    }

    /// Capsule badge showing the data_type byte in hex with a hue that
    /// categorises the packet at-a-glance. Saves the user from parsing
    /// the leading hex pair on every row.
    private var dataTypeBadge: some View {
        let (label, color) = categorise()
        return VStack(spacing: 2) {
            Text(String(format: "0x%02X", entry.bytes.first ?? 0))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(0.85))
        }
        .frame(width: 44)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color.opacity(0.30), lineWidth: 1)
        )
    }

    /// Map the data_type byte to (short label, accent colour). LAYOUT
    /// packets are by far the most frequent — calm blue mirrors the
    /// EN pill. OS handshake is rare and important — same green as the
    /// "connected" status dot. Anything else stands out as not-typical.
    private func categorise() -> (String, Color) {
        switch entry.bytes.first {
        case 0xAC: ("LAYOUT", .dsAccentENBadge)
        case 0xB0: ("OS", .dsOk)
        default: ("?", .secondary)
        }
    }

    private var productLabel: String {
        String(format: "pid=0x%04X", entry.productId)
    }

    private var timestamp: String {
        Self.formatTimestamp(entry.timestamp)
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

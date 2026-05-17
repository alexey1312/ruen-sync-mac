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

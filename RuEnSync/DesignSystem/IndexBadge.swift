import SwiftUI

// MARK: - IndexBadge

/// Capsule badge displaying a firmware layout index. Tinted to mirror
/// the menubar EN/RU pill convention — idx 0 (English) → calm blue, any
/// other idx (Russian variants) → warm coral.
///
/// `index` is `UInt8` to match the firmware wire type — the byte is
/// what `HIDLink.send(layoutIndex:)` puts on the bus, and accepting
/// `Int` at the UI boundary would silently admit negative or > 255
/// values that the wire can't represent.
struct IndexBadge: View {
    let index: UInt8

    var body: some View {
        Text("idx \(index)")
            .font(.caption.monospacedDigit().weight(.medium))
            .dsCapsule(tone: .layout(forIndex: index))
            .frame(minWidth: 48, alignment: .center)
    }
}

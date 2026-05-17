import SwiftUI

// MARK: - IndexBadge

/// Capsule badge displaying a firmware layout index. Tinted to mirror
/// the menubar EN/RU pill convention — idx 0 (English) → calm blue, any
/// other idx (Russian variants) → warm coral.
///
/// Lives in the design system because layouts table and the future
/// "current layout" indicator in the menubar dropdown should share one
/// implementation; introducing a second copy is how palettes drift.
struct IndexBadge: View {
    let index: Int

    var body: some View {
        Text("idx \(index)")
            .font(.caption.monospacedDigit().weight(.medium))
            .dsCapsule(tone: index == 0 ? .layoutEN : .layoutRU)
            .frame(minWidth: 48, alignment: .center)
    }
}

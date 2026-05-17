import SwiftUI

// MARK: - DSCapsuleTone

/// Visual tone for an inline capsule pill. Each tone bundles fill + text
/// colour so call sites just pick semantics and don't reason about hex.
enum DSCapsuleTone {
    /// Muted grey. Default for read-only metadata (product IDs, bundle IDs).
    case muted
    /// Accent-tinted background, primary text. Used to highlight a value
    /// the user might care about (current version, selected layout).
    case accent
    /// Filled with EN/RU layout tint, white text. Used by `IndexBadge`
    /// at idx 0; mirrors the menubar EN pill.
    case layoutEN
    /// Filled with RU tint, white text. Mirrors the menubar RU pill.
    case layoutRU
    /// Success-tinted, used for "Added" / "Connected" affirmations.
    case success

    var fill: Color {
        switch self {
        case .muted: Color.secondary.opacity(0.12)
        case .accent: Color.accentColor.opacity(0.15)
        case .layoutEN: Color.dsAccentENBadge.opacity(0.15)
        case .layoutRU: Color.dsAccentRUBadge.opacity(0.15)
        case .success: Color.dsOk.opacity(0.18)
        }
    }

    var foreground: Color {
        switch self {
        case .muted: .secondary
        case .accent: .primary
        case .layoutEN: .dsAccentENBadge
        case .layoutRU: .dsAccentRUBadge
        case .success: .dsOk
        }
    }
}

// MARK: - View modifier

private struct DSCapsuleModifier: ViewModifier {
    let tone: DSCapsuleTone
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(tone.foreground)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.fill)
            )
    }
}

extension View {
    /// Wraps the receiver in a tinted capsule pill. Use for inline
    /// metadata (productId, version, layout label) — keeps padding,
    /// fill, and foreground locked to the design-system tone so the
    /// same primitive renders identically everywhere.
    ///
    /// Default padding (7 × 2) matches the menubar pill rhythm and the
    /// existing AboutCard / IndexBadge spacing. Override only when the
    /// pill houses a multi-line label.
    func dsCapsule(
        tone: DSCapsuleTone,
        horizontalPadding: CGFloat = 7,
        verticalPadding: CGFloat = 2
    ) -> some View {
        modifier(DSCapsuleModifier(
            tone: tone,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        ))
    }
}

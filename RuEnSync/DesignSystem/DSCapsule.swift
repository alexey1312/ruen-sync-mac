import SwiftUI

// MARK: - DSCapsuleTone

/// Visual tone for an inline capsule pill. Each tone bundles fill +
/// foreground colour so call sites just pick semantics and don't reason
/// about hex.
enum DSCapsuleTone {
    /// Muted grey. Default for read-only metadata (product IDs, bundle IDs).
    case muted
    /// Accent-tinted background, primary text. Used to highlight a value
    /// the user might care about (current version, selected layout).
    case accent
    /// Tinted EN wash with same-hue text — the `IndexBadge` look at idx 0.
    /// NOT the menubar-pill look (which uses solid base + white glyph).
    case layoutEN
    /// Tinted RU wash with same-hue text — the `IndexBadge` look at
    /// non-zero idx. NOT the menubar-pill look.
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

// MARK: - Canonical layout-index → tone

extension DSCapsuleTone {
    /// Single source of truth for "which capsule tone goes with this
    /// layout index". Mirrors the firmware contract (`idx 0 == EN`,
    /// non-zero == RU). Call this instead of re-implementing the `== 0`
    /// branch at the call site.
    static func layout(forIndex idx: UInt8) -> DSCapsuleTone {
        idx == 0 ? .layoutEN : .layoutRU
    }
}

// MARK: - DSCapsuleSize

/// Padding rhythm for `.dsCapsule(tone:size:)`. Three named shapes cover
/// every current call site; pick the closest rather than hand-tuning
/// horizontal/vertical knobs at each use.
enum DSCapsuleSize {
    /// 7 × 2. Inline metadata (productId, version) — the AboutCard +
    /// IndexBadge rhythm. Default.
    case compact
    /// 8 × 3. Body-sized values with extra breathing room — the example
    /// cards and inline rule labels.
    case comfortable
    /// 8 × 4. Label-style pills with icon + text — the "Added" badge.
    case roomy

    var horizontal: CGFloat {
        switch self {
        case .compact: 7
        case .comfortable, .roomy: 8
        }
    }

    var vertical: CGFloat {
        switch self {
        case .compact: 2
        case .comfortable: 3
        case .roomy: 4
        }
    }
}

// MARK: - View modifier

private struct DSCapsuleModifier: ViewModifier {
    let tone: DSCapsuleTone
    let size: DSCapsuleSize

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, size.horizontal)
            .padding(.vertical, size.vertical)
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
    /// Default size `.compact` (7 × 2) matches the AboutCard and
    /// IndexBadge rhythm. The menubar pill is tighter (5 × 1) by design
    /// and intentionally does NOT route through `.dsCapsule`.
    func dsCapsule(tone: DSCapsuleTone, size: DSCapsuleSize = .compact) -> some View {
        modifier(DSCapsuleModifier(tone: tone, size: size))
    }
}

import SwiftUI

// MARK: - DSCardTone

/// Visual treatment of a `DSCard` container. Each tone bundles fill +
/// border colour so call sites don't reason about hex values directly.
enum DSCardTone {
    /// Neutral grey card on a transparent background. Default for
    /// empty-state example boxes, About card backdrops.
    case neutral
    /// Warning-tinted card. Used by the Settings error banner.
    case warning

    var fill: Color {
        switch self {
        case .neutral: Color.secondary.opacity(0.06)
        case .warning: Color.orange.opacity(0.10)
        }
    }

    var border: Color {
        switch self {
        case .neutral: Color.secondary.opacity(0.18)
        case .warning: Color.orange.opacity(0.35)
        }
    }
}

// MARK: - View modifier

private struct DSCardModifier: ViewModifier {
    let tone: DSCardTone
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tone.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tone.border, lineWidth: 1)
            )
    }
}

extension View {
    /// Wraps the receiver in a rounded card with a thin border and a
    /// tone-tinted fill. Pads it yourself before calling — the modifier
    /// only paints the background. Use for empty states, error banners,
    /// example previews, anything that benefits from visual containment
    /// without competing with the surrounding chrome.
    func dsCard(tone: DSCardTone = .neutral, cornerRadius: CGFloat = 8) -> some View {
        modifier(DSCardModifier(tone: tone, cornerRadius: cornerRadius))
    }
}

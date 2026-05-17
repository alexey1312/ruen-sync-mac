import SwiftUI

// MARK: - DSColor

/// Hand-tuned palette shared across the app. NOT system semantic colours —
/// we want the EN/RU pill in the menubar, the `IndexBadge` in Settings,
/// and the per-device status dots to read as one visual family.
///
/// When adding new tints, prefer extending this enum and routing through
/// `Color` extensions below; never introduce raw RGB literals at call
/// sites. The `MenuLabel` pill, `IndexBadge`, and `StatusDot` all depend
/// on these exact values for visual continuity, so any change ripples to
/// the menubar's appearance — change deliberately.
extension Color {
    // MARK: Layout-index tints (EN / RU pill family)

    /// Calm Apple-blue. Used for idx 0 (English) — mirrors the menubar pill.
    static let dsAccentEN = Color(red: 0.35, green: 0.60, blue: 0.98)

    /// Warm coral. Used for non-zero idx (Russian variants) — mirrors the
    /// menubar pill.
    static let dsAccentRU = Color(red: 0.92, green: 0.42, blue: 0.42)

    /// Slightly darker EN variant for capsule fills where the calmer hue
    /// reads as "primary" rather than "loud". Picked to match the
    /// `IndexBadge` look used in Settings → Layouts.
    static let dsAccentENBadge = Color(red: 0.30, green: 0.55, blue: 0.95)

    /// Slightly darker RU variant — paired with `dsAccentENBadge`.
    static let dsAccentRUBadge = Color(red: 0.88, green: 0.38, blue: 0.38)

    // MARK: Semantic status tints (StatusDot, badges)

    /// Healthy / connected / success. Calm green, not system `.green`
    /// (which is too saturated for inline pills).
    static let dsOk = Color(red: 0.30, green: 0.78, blue: 0.45)

    /// Warning / awaiting / recoverable. Amber, not system `.orange`.
    static let dsWarn = Color(red: 0.95, green: 0.62, blue: 0.20)

    /// Bad / fatal / unrecoverable. Soft red — distinct from coral RU
    /// so a failed device doesn't get confused with "Russian layout".
    static let dsBad = Color(red: 0.92, green: 0.36, blue: 0.36)

    /// Neutral grey when state is genuinely unknown.
    static let dsUnknown = Color.secondary.opacity(0.6)
}

// MARK: - Layout-index → Colour helper

extension Color {
    /// Maps a firmware layout index to the canonical EN/RU pill colour.
    /// Mirrors the firmware contract in CLAUDE.md (`[0xAC, idx]`: idx 0 == EN,
    /// non-zero == RU). `nil` index returns the neutral fallback used in
    /// `MenuLabel` when no layout has been read yet.
    ///
    /// Binary palette is intentional. If a future firmware introduces a
    /// third layout family (e.g. idx 2 == Greek), revisit this helper AND
    /// the pill colour story across `MenuLabel`, `IndexBadge`, and the
    /// HID Inspector together — they all assume two hues.
    static func dsAccent(forLayoutIndex idx: UInt8?) -> Color {
        switch idx {
        case .some(0): .dsAccentEN
        case .some: .dsAccentRU
        case .none: .secondary
        }
    }
}

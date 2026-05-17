import SwiftUI

// MARK: - StatusDot

/// Small coloured dot with a halo. Visual shorthand for "is this device /
/// system currently doing its job?". The halo softens hard edges and
/// makes the dot legible even at a row's small height; the solid inner
/// fill carries the colour, the surrounding halo is the same hue at low
/// alpha so the dot reads as a single unit.
///
/// Lives in the design system because the same primitive is used by
/// `SettingsDevicesTab` and would be reused by any future "is this
/// thing healthy?" surface (App Rules diagnostics, Activity log row).
struct StatusDot: View {
    enum Tint {
        case ok, warn, bad, unknown

        var color: Color {
            switch self {
            case .ok: .dsOk
            case .warn: .dsWarn
            case .bad: .dsBad
            case .unknown: .dsUnknown
            }
        }
    }

    let tint: Tint

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.color.opacity(0.22))
                .frame(width: 14, height: 14)
            Circle()
                .fill(tint.color)
                .frame(width: 8, height: 8)
        }
        .accessibilityHidden(true)
    }
}

import SwiftUI

// MARK: - DSErrorBanner

/// Inline warning banner for surfacing recoverable errors (save failure,
/// corrupt-config detected, network hiccup). Lives in the design system
/// so any future screen — not just `SettingsView` — can drop the same
/// banner in.
///
/// Visual: rounded card with a thin border and tinted fill rather than
/// a full-bleed coloured strip. A coloured strip reads as system alert
/// chrome — too loud for "we couldn't save, here's what to fix". The
/// contained card reads as a passive warning the user can absorb at
/// their own pace.
struct DSErrorBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dsWarn)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            DismissButton(action: onDismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .dsCard(tone: .warning)
    }
}

// MARK: - DismissButton

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(
                    Circle().fill(Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }
}

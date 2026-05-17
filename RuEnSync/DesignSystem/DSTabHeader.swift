import SwiftUI

// MARK: - DSTabHeader

/// Settings tab masthead — title + subtitle + optional trailing action.
/// Shared across Devices / Layouts / App Rules so the visual rhythm
/// (title font, subtitle line, baseline alignment, trailing button slot)
/// stays identical across tabs without three near-identical copies in
/// each file.
///
/// Trailing slot is a `some View`, not a `Button` — most tabs put a
/// `.borderedProminent` action there, but the General tab might want
/// nothing, and a future tab might want a "Refresh" icon-only button.
/// The generic slot keeps the surface flexible.
struct DSTabHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let trailing: () -> Trailing

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 12)
    }
}

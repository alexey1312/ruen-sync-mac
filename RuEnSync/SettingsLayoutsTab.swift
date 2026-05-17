import SwiftUI

// MARK: - SettingsLayoutsTab

/// Edits `config.layouts` — the ordered list of input source suffixes
/// that map to the `idx` we send to the keyboard. Index 0 is treated as
/// EN by firmware, anything else as RU. Order matters and is visualized
/// in the row as "idx N → suffix".
struct SettingsLayoutsTab: View {
    @Bindable var model: AppModel
    @State private var addPickerSelection: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSTabHeader(
                title: "Keyboard layouts",
                subtitle: "Index 0 is English to the firmware; anything else is Russian. Drag to reorder."
            )

            List {
                ForEach(model.config.layouts.indices, id: \.self) { idx in
                    LayoutRow(model: model, index: idx)
                }
                .onMove { from, to in
                    model.editConfig { $0.layouts.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.bordered)

            addBar
                .padding(.top, 12)
        }
        .padding(16)
    }

    /// Picker over enabled macOS input sources NOT already in config.layouts.
    /// The "Choose…" placeholder is rendered as a tag so the Picker has a
    /// resting state without a selection. Add button is borderedProminent
    /// — it's the primary affordance on this tab once a candidate is picked.
    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
            Picker("Add layout", selection: $addPickerSelection) {
                Text("Choose a system input source…").tag("")
                ForEach(addCandidates, id: \.self) { suffix in
                    Text("\(suffix) — \(InputSourceList.displayName(for: suffix))").tag(suffix)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)

            Button {
                addLayout(addPickerSelection)
                addPickerSelection = ""
            } label: {
                Text("Add")
                    .frame(minWidth: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(addPickerSelection.isEmpty)

            Spacer()
        }
    }

    private var addCandidates: [String] {
        let configured = Set(model.config.layouts)
        return InputSourceList.enabledKeyboardSuffixes().filter { !configured.contains($0) }
    }

    private func addLayout(_ suffix: String) {
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.editConfig { cfg in
            guard !cfg.layouts.contains(trimmed) else { return }
            cfg.layouts.append(trimmed)
        }
    }
}

// MARK: - LayoutRow

private struct LayoutRow: View {
    @Bindable var model: AppModel
    let index: Int

    var body: some View {
        if let suffix = model.config.layouts[safe: index] {
            HStack(spacing: 10) {
                // Grip-handle. Drag affordance is implicit on List rows when
                // `.onMove` is present, but users don't always discover it.
                // The handle icon hints "you can drag me by this column".
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)

                IndexBadge(index: UInt8(index))

                VStack(alignment: .leading, spacing: 1) {
                    Text(suffix)
                        .font(.body.monospaced())
                    Text(InputSourceList.displayName(for: suffix))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Up/down move buttons in addition to drag-to-reorder, so
                // the affordance is discoverable. Drag works too via
                // List.onMove above.
                Button {
                    moveUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move up")

                Button {
                    moveDown()
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index >= model.config.layouts.count - 1)
                .help("Move down")

                Button(role: .destructive) {
                    model.editConfig { $0.layouts.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.config.layouts.count <= 1)
                .help("Remove layout")
            }
            .padding(.vertical, 4)
        }
    }

    private func moveUp() {
        guard index > 0 else { return }
        model.editConfig { cfg in
            cfg.layouts.swapAt(index, index - 1)
        }
    }

    private func moveDown() {
        model.editConfig { cfg in
            guard index < cfg.layouts.count - 1 else { return }
            cfg.layouts.swapAt(index, index + 1)
        }
    }
}

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
        VStack(alignment: .leading) {
            Text("Keyboard layouts")
                .font(.headline)
            Text("The order here matches the byte sent to the keyboard. Firmware treats index 0 as English and any other index as Russian.")
                // swiftlint:disable:previous line_length
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

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
        }
        .padding()
    }

    /// Picker over enabled macOS input sources NOT already in config.layouts.
    /// Manual entry via TextField for layouts that aren't currently enabled
    /// (e.g. Russian Phonetic the user wants to pre-configure before
    /// installing it in System Settings).
    private var addBar: some View {
        HStack {
            Picker("Add layout", selection: $addPickerSelection) {
                Text("Choose…").tag("")
                ForEach(addCandidates, id: \.self) { suffix in
                    Text("\(suffix) — \(InputSourceList.displayName(for: suffix))").tag(suffix)
                }
            }
            .frame(maxWidth: 280)

            Button("Add") {
                addLayout(addPickerSelection)
                addPickerSelection = ""
            }
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
        guard let suffix = model.config.layouts[safe: index] else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 12) {
                Text("idx \(index)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                Text(suffix)
                    .font(.body.monospaced())

                Text("— \(InputSourceList.displayName(for: suffix))")
                    .foregroundStyle(.secondary)

                Spacer()

                // Up/down move buttons in addition to drag-to-reorder, so
                // the affordance is discoverable. Drag works too via
                // List.onMove above.
                Button {
                    moveUp()
                } label: {
                    Image(systemName: "arrow.up")
                } .buttonStyle(.borderless)
                    .disabled(index == 0)

                Button {
                    moveDown()
                } label: {
                    Image(systemName: "arrow.down")
                } .buttonStyle(.borderless)
                    .disabled(index >= model.config.layouts.count - 1)

                Button(role: .destructive) {
                    model.editConfig { $0.layouts.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.config.layouts.count <= 1)
            }
            .padding(.vertical, 2)
        )
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

import SwiftUI

// MARK: - DevicesTab

struct SettingsDevicesTab: View {
    @Bindable var model: AppModel
    @State private var showScan = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Configured devices")
                .font(.headline)
                .padding(.bottom, 4)

            if model.config.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("No devices configured.")
                    Text("Plug in your keyboard and tap *Scan…* to add it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.config.devices.indices, id: \.self) { idx in
                        DeviceRow(model: model, index: idx)
                    }
                }
                .listStyle(.bordered)
                .frame(maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button("Scan…") { showScan = true }
                    .keyboardShortcut("r")
            }
        }
        .padding()
        .sheet(isPresented: $showScan) {
            ScanSheet(model: model, isPresented: $showScan)
        }
    }
}

/// Editable device row: name is editable via TextField (commit on blur),
/// productId is read-only because changing it would invalidate the live
/// HIDLink and the user almost always wants to "Remove + Scan + Add"
/// instead, which forces the right pid through the scanner.
private struct DeviceRow: View {
    @Bindable var model: AppModel
    let index: Int

    @State private var nameDraft: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let device = model.config.devices[safe: index] {
            HStack(spacing: 8) {
                TextField("Device name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }

                Text(device.productId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)

                Button(role: .destructive) {
                    model.editConfig { $0.devices.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
            .onAppear { nameDraft = device.name }
            .onChange(of: device) { _, newDevice in nameDraft = newDevice.name }
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Refuse empty names; restore previous draft. Avoids accidentally
            // ending up with a blank label in the menubar.
            nameDraft = model.config.devices[safe: index]?.name ?? ""
            return
        }
        model.editConfig { cfg in
            guard index < cfg.devices.count else { return }
            let old = cfg.devices[index]
            cfg.devices[index] = .init(
                name: trimmed,
                productId: old.productId,
                usagePage: old.usagePage,
                usage: old.usage
            )
        }
    }
}

private struct ScanSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var discovered: [DiscoveredDevice] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Discovered keyboards")
                    .font(.headline)
                Spacer()
                Button("Rescan") { rescan() }
            }

            Divider()

            if discovered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("No QMK Raw HID keyboards detected.")
                    Text(
                        "Confirm the keyboard is plugged in and that the firmware exposes UsagePage 0xFF60 / Usage 0x61."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discovered) { device in
                    ScanRow(device: device, model: model)
                }
                .listStyle(.bordered)
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 460, height: 340)
        .onAppear { rescan() }
    }

    private func rescan() {
        discovered = DeviceDiscovery.scan()
    }
}

private struct ScanRow: View {
    let device: DiscoveredDevice
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.displayName)
                Text("\(device.productIdHex) — \(device.manufacturer ?? "Unknown")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if alreadyConfigured {
                Text("Added").foregroundStyle(.secondary).font(.caption)
            } else {
                Button("Add") { addDevice() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }

    private var alreadyConfigured: Bool {
        model.config.devices.contains { entry in
            ResolvedDevice.parseHex(entry.productId) == device.productId
        }
    }

    private func addDevice() {
        let pid = device.productIdHex
        let name = device.displayName
        model.editConfig {
            $0.devices.append(.init(name: name, productId: pid, usagePage: nil, usage: nil))
        }
    }
}

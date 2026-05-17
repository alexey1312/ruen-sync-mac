import SwiftUI

// MARK: - DevicesTab

struct SettingsDevicesTab: View {
    @Bindable var model: AppModel
    @State private var showScan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSTabHeader(
                title: "Configured devices",
                subtitle: "Keyboards RuEnSync watches for sync events."
            ) {
                Button {
                    showScan = true
                } label: {
                    Label("Scan…", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r")
            }

            if model.config.devices.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.config.devices.indices, id: \.self) { idx in
                        DeviceRow(model: model, index: idx)
                    }
                }
                .listStyle(.bordered)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .sheet(isPresented: $showScan) {
            ScanSheet(model: model, isPresented: $showScan)
        }
    }

    /// Empty state — only seen when the user has explicitly removed every
    /// device (or the very first launch where auto-discovery found nothing).
    /// Big, centred call-to-action rather than a thin secondary line.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No devices configured")
                .font(.headline)
            Text("Plug your keyboard in and tap **Scan…** to add it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showScan = true
            } label: {
                Label("Scan for keyboards", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
            HStack(spacing: 10) {
                StatusDot(tint: dotTint(for: device))
                    .help(dotHelp(for: device))

                TextField("Device name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }

                Text(device.productId)
                    .font(.caption.monospaced())
                    .dsCapsule(tone: .muted, horizontalPadding: 6)
                    .frame(minWidth: 64, alignment: .trailing)

                Button(role: .destructive) {
                    model.editConfig { $0.devices.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove device")
            }
            .padding(.vertical, 4)
            .onAppear { nameDraft = device.name }
            .onChange(of: device) { _, newDevice in nameDraft = newDevice.name }
        }
    }

    /// Resolves the row's live link state by matching the config row's
    /// productId hex against `model.deviceStatuses`. Matching by pid
    /// rather than array index keeps us robust when an unparseable
    /// device in config has been silently filtered out of
    /// deviceStatuses (which would otherwise misalign the indices).
    private func liveStatus(for device: Config.Device) -> HIDLink.State? {
        guard let pid = ResolvedDevice.parseHex(device.productId) else { return nil }
        return model.deviceStatuses.first { $0.productId == pid }?.state
    }

    private func dotTint(for device: Config.Device) -> StatusDot.Tint {
        guard let state = liveStatus(for: device) else { return .unknown }
        switch state {
        case .connected:
            return .ok
        case let .offline(reason):
            switch reason {
            case .awaitingDevice, .exclusiveAccess:
                return .warn
            case .openFailed, .managerOpenFailed:
                return .bad
            }
        }
    }

    private func dotHelp(for device: Config.Device) -> String {
        guard let state = liveStatus(for: device) else { return String(localized: "Unknown status") }
        switch state {
        case .connected:
            return String(localized: "Connected")
        case let .offline(reason):
            return reason.menuLabel
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
        VStack(alignment: .leading, spacing: 0) {
            DSTabHeader(
                title: "Discovered keyboards",
                subtitle: "UsagePage 0xFF60 / Usage 0x61 — QMK Raw HID interface."
            ) {
                Button {
                    rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }

            if discovered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No QMK Raw HID keyboards detected.")
                        .font(.headline)
                    Text(
                        "Confirm the keyboard is plugged in and that the firmware exposes UsagePage 0xFF60 / Usage 0x61."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
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
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 480, height: 360)
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
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(device.productIdHex)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(device.manufacturer ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if alreadyConfigured {
                Label("Added", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .dsCapsule(tone: .muted, horizontalPadding: 8, verticalPadding: 4)
            } else {
                Button("Add") { addDevice() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
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

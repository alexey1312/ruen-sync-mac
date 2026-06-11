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

/// Three-state resolution of a config row to its live HIDLink. We split
/// "the productId is malformed and we'll NEVER build a link" from "the
/// link hasn't reported yet" because they look identical to the user
/// otherwise — both render a grey dot — but the former is permanent and
/// needs a louder tooltip + colour.
private enum LiveDeviceStatus {
    /// The config row's productId hex failed to parse. `AppModel.buildAndStartLinks`
    /// silently skips this row, so no `HIDLink` exists for it. Permanent
    /// until the user fixes the JSON.
    case invalidProductId
    /// Parses fine, but no matching status has been reported yet (transient
    /// race on launch / reconnect).
    case pending
    /// Live link state from `model.deviceStatuses`.
    case known(HIDLink.State)
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
                    .dsCapsule(tone: .muted)
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

    /// Resolves the row's live state. Distinguishes three cases that
    /// would otherwise collapse into a single `nil`:
    ///   1. unparseable productId — the row will never become live
    ///      because `AppModel.buildAndStartLinks` filters it out;
    ///   2. parses but no status reported yet (transient race);
    ///   3. parses and has a matching `deviceStatuses` entry.
    /// Matching by pid (not array index) keeps us robust when an
    /// unparseable device in config has been silently filtered out of
    /// `deviceStatuses` (which would otherwise misalign the indices).
    private func liveStatus(for device: Config.Device) -> LiveDeviceStatus {
        guard let pid = ResolvedDevice.parseHex(device.productId) else {
            return .invalidProductId
        }
        if let state = model.deviceStatusesDict[pid] {
            return .known(state)
        }
        return .pending
    }

    private func dotTint(for device: Config.Device) -> StatusDot.Tint {
        switch liveStatus(for: device) {
        case .invalidProductId:
            .bad
        case .pending:
            .unknown
        case let .known(state):
            switch state {
            case .connected:
                .ok
            case let .offline(reason):
                switch reason {
                case .awaitingDevice, .exclusiveAccess:
                    .warn
                case .openFailed, .managerOpenFailed:
                    .bad
                }
            }
        }
    }

    private func dotHelp(for device: Config.Device) -> String {
        switch liveStatus(for: device) {
        case .invalidProductId:
            String(localized: "Invalid productId — RuEnSync can't open this device")
        case .pending:
            String(localized: "Unknown status")
        case let .known(state):
            switch state {
            case .connected:
                String(localized: "Connected")
            case let .offline(reason):
                reason.menuLabel
            }
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
                    .dsCapsule(tone: .muted, size: .roomy)
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

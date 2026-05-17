import SwiftUI

// MARK: - SettingsView

/// Root of the Preferences window (opened by Cmd+, or
/// "Settings…" in the menubar). Tabbed because the surface area is varied:
/// device list, app-rule table, autostart and debug toggles — each gets a
/// dedicated tab so the window doesn't become an unsorted Form.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gear") }

            DevicesTab(model: model)
                .tabItem { Label("Devices", systemImage: "keyboard") }

            AppRulesTab(model: model)
                .tabItem { Label("App Rules", systemImage: "app.badge") }

            DebugTab(model: model)
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin: Bool = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if newValue {
                            LoginItem.registerIfNeeded()
                        } else {
                            LoginItem.unregister()
                        }
                        // Re-sync from system in case the call failed (e.g.
                        // user hit "Don't Allow" in System Settings).
                        launchAtLogin = LoginItem.isEnabled
                    }
                Text("Open *System Settings → General → Login Items* to revoke approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Per-app layout switching") {
                Toggle("Auto-switch by app", isOn: Binding(
                    get: { model.appLayoutSwitchingEnabled },
                    set: { newValue in
                        model.editConfig { $0.appLayoutSwitchingEnabled = newValue }
                    }
                ))
                Text("When on, activating an app listed in the App Rules tab automatically switches the macOS input source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Devices

private struct DevicesTab: View {
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

private struct DeviceRow: View {
    @Bindable var model: AppModel
    let index: Int

    var body: some View {
        let device = model.config.devices[index]
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                Text(device.productId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.editConfig { $0.devices.remove(at: index) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
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
                    Text("Confirm the keyboard is plugged in and that the firmware exposes UsagePage 0xFF60 / Usage 0x61.")
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

// MARK: - App Rules

private struct AppRulesTab: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("App layout rules")
                .font(.headline)
            Text("Match by exact bundle ID or by prefix. Exact wins over prefix; among prefixes, the longest match wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            let rules = model.config.appLayoutRules ?? []
            if rules.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "app.badge")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("No rules yet. Add one below.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules.indices, id: \.self) { idx in
                        AppRuleRow(model: model, index: idx)
                    }
                }
                .listStyle(.bordered)
            }

            HStack {
                Spacer()
                Button("Add rule") {
                    model.editConfig {
                        var list = $0.appLayoutRules ?? []
                        let firstLayout = $0.layouts.first ?? "ABC"
                        list.append(.init(bundleId: "com.example.app", bundleIdPrefix: nil, layout: firstLayout))
                        $0.appLayoutRules = list
                    }
                }
            }
        }
        .padding()
    }
}

private struct AppRuleRow: View {
    @Bindable var model: AppModel
    let index: Int

    var body: some View {
        let rule = (model.config.appLayoutRules ?? [])[index]
        HStack {
            VStack(alignment: .leading) {
                Text(rule.bundleId ?? rule.bundleIdPrefix.map { "\($0)*" } ?? "—")
                    .font(.body.monospaced())
                Text("→ \(rule.layout)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.editConfig {
                    var list = $0.appLayoutRules ?? []
                    guard index < list.count else { return }
                    list.remove(at: index)
                    $0.appLayoutRules = list.isEmpty ? nil : list
                }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Debug

private struct DebugTab: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("HID Inspector") {
                Toggle("Record HID writes", isOn: Binding(
                    get: { model.config.debug?.hidInspector ?? false },
                    set: { newValue in
                        model.editConfig {
                            var dbg = $0.debug ?? Config.Debug()
                            dbg.hidInspector = newValue
                            $0.debug = dbg
                        }
                    }
                ))
                Text("Captures every outgoing packet in a ring buffer for the Inspector window. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Inspector") {
                    openWindow(id: "hid-inspector")
                }
            }

            Section("Diagnostics") {
                Text("Bundle logs, current config, the activity DB, and the packet buffer into a zip in ~/Downloads — useful for bug reports.")
                    // swiftlint:disable:previous line_length
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Export diagnostics…") {
                    Task {
                        let packetLog = model.packetLog
                        if let url = await Diagnostics.exportZip(packetLog: packetLog) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

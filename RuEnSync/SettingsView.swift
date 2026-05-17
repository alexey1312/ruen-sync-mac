import SwiftUI

// MARK: - SettingsView

/// Root of the Preferences window (opened by Cmd+, or
/// "Settings…" in the menubar). Tabbed because the surface area is varied:
/// device list, app-rule table, autostart and debug toggles — each gets a
/// dedicated tab so the window doesn't become an unsorted Form.
///
/// The Devices and App Rules tabs are heavy enough to deserve their own
/// files (`SettingsDevicesTab.swift`, `SettingsAppRulesTab.swift`) — this
/// keeps each under the project-wide 400-line lint cap.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gear") }

            SettingsDevicesTab(model: model)
                .tabItem { Label("Devices", systemImage: "keyboard") }

            SettingsLayoutsTab(model: model)
                .tabItem { Label("Layouts", systemImage: "globe") }

            SettingsAppRulesTab(model: model)
                .tabItem { Label("App Rules", systemImage: "app.badge") }

            DebugTab(model: model)
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .frame(width: 560, height: 400)
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

            Section("About") {
                LabeledContent("Version", value: Self.versionLabel)
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "?")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// "1.0.0 (42)" — short version + build number. Falls back gracefully
    /// when running an Info.plist-less unit-test target.
    private static var versionLabel: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
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

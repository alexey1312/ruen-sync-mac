import AppKit
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
        VStack(spacing: 0) {
            if let errorText = model.lastSettingsError {
                DSErrorBanner(text: errorText) {
                    model.lastSettingsError = nil
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
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
        }
        .frame(width: 620, height: 460)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin: Bool = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                AboutCard()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

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
                Text(
                    "When on, activating an app listed in the App Rules tab automatically switches the macOS input source."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Hero card at the top of General. Replaces a flat "Version / Bundle"
/// LabeledContent pair with a visually anchored identity block: app icon,
/// product name, tagline, and the version/bundle stamped as metadata
/// underneath. Gives the Settings window a recognisable masthead and makes
/// the version far more glanceable than buried in a Form row.
private struct AboutCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // NSImage(named: NSImage.applicationIconName) returns the real
            // app icon at the requested size; we render it via Image to keep
            // it crisp on Retina.
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.tertiary)
                    .frame(width: 56, height: 56)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("RuEnSync")
                    .font(.title3.weight(.semibold))
                Text("Keeps your QMK keyboard's `cur_lang` in sync with macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    versionBadge
                    bundleBadge
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var versionBadge: some View {
        Text(Self.versionLabel)
            .font(.caption.monospacedDigit())
            .dsCapsule(tone: .accent)
    }

    private var bundleBadge: some View {
        Text(Bundle.main.bundleIdentifier ?? "?")
            .font(.caption2.monospaced())
            .dsCapsule(tone: .muted)
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
                Text(
                    "Bundle logs, current config, the activity DB, and the packet buffer "
                        + "into a zip in ~/Downloads — useful for bug reports."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Export diagnostics…") {
                    Task {
                        let packetLog = model.packetLog
                        let result = await Diagnostics.exportZip(packetLog: packetLog)
                        Diagnostics.handleExportResult(result, surfaceTo: model)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

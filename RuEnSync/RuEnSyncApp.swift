import AppKit
import SwiftUI

// MARK: - @main

@main
struct RuEnSyncApp: App {
    @State private var model: AppModel
    /// Sparkle controller has to outlive the app — keeping it as @State (a
    /// reference type stays put-by-identity) is the documented pattern.
    @State private var updater = Updater()

    init() {
        // Classify the on-disk config before deciding whether to seed the
        // default OR run auto-discovery. The three outcomes are deliberately
        // separated: a corrupt file must NOT be replaced silently, and
        // first-run auto-discovery must NOT fire on top of a corrupt file
        // (which would overwrite the recoverable bad config with a
        // discovered-devices shell).
        let result = ConfigStore.load()
        let config: Config
        var initialError: String?
        var allowAutoDiscovery = true
        switch result {
        case let .loaded(loaded):
            config = loaded
        case .missing:
            ConfigStore.seedDefaultIfMissing()
            config = .default
        case let .corrupt(error):
            config = .default
            allowAutoDiscovery = false
            initialError =
                String(
                    localized: "Config file at \(ConfigStore.configURL.path) failed to load: \(error.localizedDescription). Running with defaults until you fix or remove it."
                )
            Log.config.error(
                "startup: refusing to overwrite corrupt config at \(ConfigStore.configURL.path, privacy: .public)"
            )
        }
        let model = AppModel(config: config, allowAutoDiscoverySeed: allowAutoDiscovery)
        model.lastSettingsError = initialError
        _model = State(initialValue: model)
        // Register as a login item on first launch. Idempotent — SMAppService
        // is safe to call repeatedly.
        LoginItem.registerIfNeeded()
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updater: updater)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        // Standalone window for the HID Inspector. `defaultSize` keeps the
        // window non-zero on first show; subsequent positions/sizes are
        // remembered by AppKit via `Restorable`. Identified by id so the
        // menubar can pop it open with `@Environment(\.openWindow)`.
        Window("HID Inspector", id: "hid-inspector") {
            HIDInspectorView(packetLog: model.packetLog)
        }
        .defaultSize(width: 640, height: 480)
        .windowResizability(.contentMinSize)

        // Standard macOS Preferences/Settings window — wired to Cmd+,
        // and to the "Settings…" menubar item.
        Settings {
            SettingsView(model: model)
        }
    }
}

// MARK: - Menu label (icon in the menubar)

/// EN/RU pill rendered into the menubar. Visual goals:
///
/// 1. Calm, not loud. The default `.red`/`.blue` system colors are tuned for
///    accent contexts (buttons, links) and read as aggressive shouting in a
///    16-pt-tall menubar slot. Hand-tuned, slightly desaturated hues sit
///    closer to "tag colour" than "alarm".
/// 2. Equal optical width. EN and RU have different glyph widths in
///    proportional fonts; using monospaced digits + tight horizontal padding
///    keeps the pill width constant so the surrounding menubar layout
///    doesn't jitter on every layout change.
/// 3. Background pill softens the colour and gives the letter pair a
///    container, so it reads as one symbol instead of two loose glyphs.
/// 4. Filled pill = packets currently reaching at least one device. Hollow,
///    desaturated pill = sync is broken (no device connected / busy /
///    qmk-hid-host holding the lock). The dropdown carries the actual
///    reason; the menubar just answers "is sync working right now?".
/// 5. Online pill uses a near-opaque fill + white text rather than a tinted
///    glyph on a translucent tint of the same hue. The translucent form
///    silently broke on coloured wallpapers — a blue desktop turned the
///    menubar bluish too, and the EN pill (same hue throughout) disappeared
///    into it. White-on-saturated-colour is an isoluminance-safe contrast
///    that survives any wallpaper tint.
private struct MenuLabel: View {
    let model: AppModel

    var body: some View {
        // MenuBarExtra with .menu style force-renders `Text` in the system
        // menubar tint and silently ignores `.foregroundStyle`. To actually
        // colour the EN/RU label we render the SwiftUI view into an NSImage
        // via ImageRenderer and mark it non-template, so AppKit treats it as
        // a bitmap and keeps our colour. Re-renders on every layoutIndex /
        // device-status change because the @Observable reads in
        // `renderedLabel` invalidate the body. Tiny cost (a few pixels of
        // text) — fine on the main loop.
        if let nsImage = renderedLabel {
            Image(nsImage: nsImage)
                .accessibilityLabel(accessibilityLabel)
        } else {
            Text(model.languageLabel)
        }
    }

    /// Hand-tuned colours, NOT system `.red`/`.blue`. See goal (1) on
    /// `MenuLabel`. Light/dark menubar both work because the pill sits on
    /// top of the menubar's blur, not on raw white/black.
    private var baseColor: Color {
        switch model.layoutIndex {
        case .some(0): Color(red: 0.35, green: 0.60, blue: 0.98) // calm Apple-blue
        case .some: Color(red: 0.92, green: 0.42, blue: 0.42) // warm coral
        case .none: .secondary
        }
    }

    /// Online: white glyph for guaranteed contrast against the saturated
    /// pill underneath (works on light AND dark menubars, regardless of
    /// wallpaper tint). Offline: muted base hue at half-alpha — the pill
    /// fades to "ghost" without disappearing, and the colour still hints at
    /// the current macOS layout.
    private var foreground: Color {
        model.isAnyDeviceConnected ? .white : baseColor.opacity(0.5)
    }

    /// Solid base colour when online so the pill carries its own contrast
    /// instead of relying on the menubar blur (which tints with the
    /// wallpaper underneath and could match our hue). `.clear` when offline,
    /// combined with the stroke, flips the pill from filled-tag to
    /// outlined-tag without changing its footprint.
    private var background: Color {
        model.isAnyDeviceConnected ? baseColor : .clear
    }

    /// Invisible when online (the solid fill is the boundary); outlined in
    /// the muted base hue when offline.
    private var strokeColor: Color {
        model.isAnyDeviceConnected ? .clear : baseColor.opacity(0.55)
    }

    private var accessibilityLabel: String {
        model.isAnyDeviceConnected ? model.languageLabel : "\(model.languageLabel), no device connected"
    }

    @MainActor
    private var renderedLabel: NSImage? {
        let view = Text(model.languageLabel)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .kerning(0.3)
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}

// MARK: - Menu content (dropdown)

private struct MenuContent: View {
    let model: AppModel
    let updater: Updater
    @State private var showActivity = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("RuEnSync")
            .font(.headline)

        Divider()

        if let yieldedTo = model.yieldedTo {
            // Yielded state takes the whole device-list slot — there's no
            // useful per-device status while we're not even trying to open
            // the endpoint. "Resume anyway" is escape-hatch for users whose
            // conflicting app is already done but didn't quit (background
            // tab, hidden window).
            Label("Paused — \(yieldedTo) is running", systemImage: "pause.circle.fill")
            Text("RuEnSync released the keyboard so \(yieldedTo) can use it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Resume anyway") {
                model.forceResume()
            }
        } else if model.deviceStatuses.isEmpty {
            Label("No device configured", systemImage: "keyboard.badge.ellipsis")
        } else {
            ForEach(model.deviceStatuses) { status in
                MenubarDeviceRow(status: status)
            }
        }

        if model.yieldedTo == nil, model.isAnyDeviceConnected {
            Text("Layout: \(model.languageLabel)")
        }

        Divider()

        // The activity log lives in a sub-menu rather than inline. .menu-style
        // MenuBarExtra renders sub-menus as a side-anchored fly-out, which is
        // the same affordance the user wanted (hover-to-reveal) without the
        // two-NSPanel cascade that zero-code uses. Keeps the main dropdown
        // short while exposing the full log on demand.
        Menu("Activity (\(model.activity.entries.count))") {
            if model.activity.entries.isEmpty {
                Text("No activity yet")
            } else {
                ForEach(model.activity.entries.prefix(20)) { entry in
                    ActivityRow(entry: entry)
                }
                Divider()
                Button("Clear activity") {
                    model.activity.clear()
                }
            }
        }

        Divider()

        Button("Reconnect") {
            model.reconnectAll()
        }
        .keyboardShortcut("r")

        // Quick toggle for per-app switching, mirroring the
        // `appLayoutSwitchingEnabled` flag in config.json. Only shown when
        // at least one rule exists — otherwise the toggle would be a no-op
        // and adds confusing surface area. Persists through `editConfig` so
        // the choice survives quit/relaunch — the menubar and the Settings
        // checkbox share the same on-disk state.
        if model.hasAppLayoutRules {
            Toggle("Auto-switch by app", isOn: Binding(
                get: { model.appLayoutSwitchingEnabled },
                set: { newValue in
                    model.editConfig { $0.appLayoutSwitchingEnabled = newValue }
                }
            ))
        }

        Button("Settings…") {
            // SwiftUI's Settings scene doesn't always bring its window to
            // front for menubar apps — explicitly activating ensures the
            // window appears in front of the active app's windows.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Open config…") {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.configURL])
        }

        Button("Open log…") {
            openLogStream()
        }

        Divider()

        Menu("Debug") {
            Button("HID Inspector…") {
                openWindow(id: "hid-inspector")
            }
            Button("Export diagnostics…") {
                Task {
                    let packetLog = model.packetLog
                    let result = await Diagnostics.exportZip(packetLog: packetLog)
                    Diagnostics.handleExportResult(result, surfaceTo: model)
                }
            }
        }

        Divider()

        CheckForUpdatesMenuItem(updater: updater)

        Button("Quit RuEnSync") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Launches Terminal with a `log stream` predicate scoped to our subsystem.
    /// Implementation note: we write a temporary `.command` file and let
    /// `NSWorkspace.open` route it to Terminal via LaunchServices. Avoids the
    /// AppleScript / NSAppleEventDescriptor path, which would trigger a TCC
    /// prompt for "Automation → Terminal" on first use.
    private func openLogStream() {
        // Per-launch unique name: prevents an attacker who can write to
        // $TMPDIR from pre-planting a symlink at a known path (which our
        // chmod would then redirect), and avoids collisions if a debug build
        // is running alongside.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuEnSync-log-\(UUID().uuidString).command")
        let content = """
        #!/bin/bash
        clear
        echo "RuEnSync — live log (Ctrl-C to stop)"
        echo
        exec log stream --predicate 'subsystem == "\(Log.subsystem)"' --info
        """
        do {
            // .withoutOverwriting refuses to follow a pre-existing symlink at
            // the path. 0o700 keeps the script readable only by us.
            try Data(content.utf8).write(to: scriptURL, options: [.atomic, .withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            guard NSWorkspace.shared.open(scriptURL) else {
                Log.app
                    .error(
                        "openLogStream: no app registered for .command — install Terminal or set a default opener"
                    )
                return
            }
        } catch {
            let nsError = error as NSError
            Log.app
                .error(
                    "openLogStream failed: \(nsError.domain, privacy: .public) code=\(nsError.code) — \(nsError.localizedDescription, privacy: .public)"
                )
        }
    }
}

// `CheckForUpdatesMenuItem`, `DeviceRow`, `ActivityRow` moved to
// `MenuBarViews.swift` so this file stays under the 400-line lint cap.

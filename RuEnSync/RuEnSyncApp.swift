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
        let config = ConfigStore.loadOrSeedDefaults()
        let model = AppModel(config: config)
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
private struct MenuLabel: View {
    let model: AppModel

    var body: some View {
        // MenuBarExtra with .menu style force-renders `Text` in the system
        // menubar tint and silently ignores `.foregroundStyle`. To actually
        // colour the EN/RU label we render the SwiftUI view into an NSImage
        // via ImageRenderer and mark it non-template, so AppKit treats it as
        // a bitmap and keeps our colour. Re-renders on every layoutIndex
        // change because the @Observable read in `renderedLabel` invalidates
        // the body. Tiny cost (a few pixels of text) — fine on the main loop.
        if let nsImage = renderedLabel {
            Image(nsImage: nsImage)
                .accessibilityLabel(model.languageLabel)
        } else {
            Text(model.languageLabel)
        }
    }

    /// Hand-tuned colours, NOT system `.red`/`.blue`. See goal (1) on
    /// `MenuLabel`. Light/dark menubar both work because the pill sits on
    /// top of the menubar's blur, not on raw white/black.
    private var foreground: Color {
        switch model.layoutIndex {
        case .some(0): Color(red: 0.35, green: 0.60, blue: 0.98) // calm Apple-blue
        case .some: Color(red: 0.92, green: 0.42, blue: 0.42) // warm coral
        case .none: .secondary
        }
    }

    private var background: Color {
        foreground.opacity(0.18)
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

    var body: some View {
        Text("RuEnSync")
            .font(.headline)

        Divider()

        if model.deviceStatuses.isEmpty {
            Label("No device configured", systemImage: "keyboard.badge.ellipsis")
        } else {
            ForEach(model.deviceStatuses) { status in
                DeviceRow(status: status)
            }
        }

        if model.isAnyDeviceConnected {
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

        Button("Open config…") {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.configURL])
        }

        Button("Open log…") {
            openLogStream()
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

// MARK: - Updates

/// Menu item that triggers Sparkle's update check. We can't bind directly to
/// `updater.canCheckForUpdates` because Sparkle's `SPUUpdater` is KVO-based,
/// not `@Observable`; the view-model in `Updater.swift` bridges KVO into
/// `@Published`, which SwiftUI's `@StateObject` knows how to track. This is
/// the pattern Sparkle's own SwiftUI docs recommend.
///
/// `@StateObject` rather than `@ObservedObject`: this view owns the lifetime
/// of `CheckForUpdatesViewModel`. With `@ObservedObject`, a parent re-render
/// would rebuild the VM (and its KVO subscription), silently breaking the
/// disable-while-checking behaviour.
private struct CheckForUpdatesMenuItem: View {
    let updater: Updater
    @StateObject private var checker: CheckForUpdatesViewModel

    init(updater: Updater) {
        self.updater = updater
        _checker = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater.updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let status: AppModel.DeviceStatus

    var body: some View {
        Label(status.summary, systemImage: symbol)
        Text("Product ID: \(status.productIdLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch status.state {
        case .connected: "keyboard.fill"
        case let .offline(reason):
            switch reason {
            case .exclusiveAccess: "exclamationmark.triangle.fill"
            case .openFailed, .managerOpenFailed: "xmark.octagon"
            case .awaitingDevice: "keyboard.badge.ellipsis"
            }
        }
    }
}

// MARK: - Activity row

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        // One menu item per entry. Native .menu sub-menus don't let us put
        // arbitrary multi-line views inside a row, so we lean on Label's
        // built-in icon + headline layout and put the timestamp on the line.
        Label("\(entry.kind.headline) — \(entry.relativeTimestamp())", systemImage: entry.kind.symbol)
    }
}

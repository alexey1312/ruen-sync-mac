import AppKit
import SwiftUI

// MARK: - @main

@main
struct RuEnSyncApp: App {
    @State private var model: AppModel

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
            MenuContent(model: model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu label (icon in the menubar)

private struct MenuLabel: View {
    let model: AppModel

    var body: some View {
        // MenuBarExtra with .menu style force-renders `Text` in the system
        // menubar tint and silently ignores `.foregroundStyle`. To actually
        // colour the EN/RU label we render the SwiftUI text into an NSImage
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

    /// EN — blue, RU — red, unknown — secondary grey.
    private var color: Color {
        switch model.layoutIndex {
        case .some(0): .blue
        case .some: .red
        case .none: .secondary
        }
    }

    @MainActor
    private var renderedLabel: NSImage? {
        let view = Text(model.languageLabel)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(color)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}

// MARK: - Menu content (dropdown)

private struct MenuContent: View {
    let model: AppModel
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

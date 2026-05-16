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
        Text(model.languageLabel)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(color)
    }

    /// EN — blue, RU — red, unknown — secondary grey. macOS auto-adjusts the
    /// shade for dark/light menubar, so plain `.blue`/`.red` are correct here.
    private var color: Color {
        switch model.layoutIndex {
        case .some(0): .blue
        case .some: .red
        case .none: .secondary
        }
    }
}

// MARK: - Menu content (dropdown)

private struct MenuContent: View {
    let model: AppModel

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

        if model.connection == .connected {
            Text("Layout: \(model.languageLabel)")
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
    /// `NSWorkspace.open` route it to Terminal via LaunchServices. This avoids
    /// the AppleScript path, which under the hardened runtime would require an
    /// `apple-events` entitlement (and a first-launch TCC prompt).
    private func openLogStream() {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("RuEnSync-log.command")
        let content = """
        #!/bin/bash
        clear
        echo "RuEnSync — live log (Ctrl-C to stop)"
        echo
        exec log stream --predicate 'subsystem == "\(Log.subsystem)"' --info
        """
        do {
            try content.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
        } catch {
            Log.app.error("openLogStream failed: \(error.localizedDescription, privacy: .public)")
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
        case .offline:
            switch status.offlineReason {
            case .exclusiveAccess: "exclamationmark.triangle.fill"
            case .openFailed, .managerOpenFailed: "xmark.octagon"
            case .awaitingDevice, .none: "keyboard.badge.ellipsis"
            }
        }
    }
}

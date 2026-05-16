import SwiftUI

// MARK: - @main

@main
struct RuEnSyncApp: App {
    @State private var model: AppModel
    @State private var config: Config

    init() {
        let config = ConfigStore.loadOrSeedDefaults()
        let model = AppModel(config: config)
        _config = State(initialValue: config)
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

        // Connection status row — name of the device + state.
        Label(model.connectionDescription, systemImage: connectionSymbol)

        if model.connection == .connected {
            Text("Layout: \(model.languageLabel)")
        }

        if let pid = model.productIdLabel {
            Text("Product ID: \(pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Open config…") {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.configURL])
        }

        Button("Quit RuEnSync") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// SF Symbol for the connection-status row. `keyboard.fill` when we're
    /// talking to the device, `keyboard.badge.ellipsis` while waiting.
    private var connectionSymbol: String {
        switch model.connection {
        case .connected: "keyboard.fill"
        case .offline: "keyboard.badge.ellipsis"
        }
    }
}

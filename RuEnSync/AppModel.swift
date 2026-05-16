import Foundation
import Observation

// MARK: - AppModel

/// Top-level reactive state shared by the menubar UI and the background
/// watchers. Owned by `RuEnSyncApp`, observed by `MenuBarExtra` content.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case offline
        case connected
    }

    /// 0 = EN, anything else = RU (firmware convention). `nil` until the
    /// first layout read.
    private(set) var layoutIndex: UInt8?
    private(set) var connection: Connection = .offline

    /// Device descriptor we're trying to talk to. Populated from `config.devices[0]`.
    /// `nil` only in the (malformed config) observe-only mode.
    let device: ResolvedDevice?

    private let hidLink: HIDLink
    private let layoutWatcher: LayoutWatcher

    init(config: Config) {
        guard
            let firstDevice = config.devices.first,
            let resolved = ResolvedDevice(firstDevice)
        else {
            Log.app.error("no usable device in config — running in observe-only mode")
            // Use a sentinel device so HIDLink doesn't match anything real.
            // Layout changes are still observed and logged.
            let placeholder = ResolvedDevice(
                .init(name: "none", productId: "0x0000", usagePage: nil, usage: nil)
            )!
            self.device = nil
            self.hidLink = HIDLink(device: placeholder)
            self.layoutWatcher = LayoutWatcher(layouts: config.layouts)
            return
        }

        self.device = resolved
        self.hidLink = HIDLink(device: resolved)
        self.layoutWatcher = LayoutWatcher(layouts: config.layouts)
    }

    /// Wires up the watchers. Call once after init, on the main actor.
    func start() {
        hidLink.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .offline:
                self.connection = .offline
            case .connected:
                self.connection = .connected
                // On reconnect, push the last known state so the firmware
                // doesn't sit at whatever it had pre-disconnect.
                if let idx = self.layoutWatcher.lastIndex {
                    self.hidLink.send(layoutIndex: idx)
                }
            }
        }

        layoutWatcher.onLayoutChanged = { [weak self] idx in
            guard let self else { return }
            self.layoutIndex = idx
            self.hidLink.send(layoutIndex: idx)
        }

        hidLink.start()
        layoutWatcher.start()
    }
}

// MARK: - Display helpers

extension AppModel {
    /// Short language label (`EN`, `RU`, or `—` when status is unknown).
    var languageLabel: String {
        switch layoutIndex {
        case .some(0): return "EN"
        case .some: return "RU"
        case .none: return "—"
        }
    }

    /// Human-readable connection status for the dropdown menu.
    var connectionDescription: String {
        switch connection {
        case .offline:
            return device.map { "\($0.name) — not connected" } ?? "No device configured"
        case .connected:
            return device.map { "\($0.name) — connected" } ?? "Connected"
        }
    }

    /// Hex form of the configured productId — useful for debug rows.
    var productIdLabel: String? {
        device.map { String(format: "0x%04X", $0.productId) }
    }
}

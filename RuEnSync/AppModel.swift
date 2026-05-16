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

    /// One row per configured device. Order matches `config.devices`. The
    /// menubar renders one line per status.
    struct DeviceStatus: Equatable, Identifiable {
        let id: UInt32 // productId — unique within a single user's config
        let name: String
        let productId: UInt32
        var state: HIDLink.State
        var offlineReason: HIDLink.OfflineReason?
    }

    /// 0 = EN, anything else = RU (firmware convention). `nil` until the
    /// first layout read.
    private(set) var layoutIndex: UInt8?

    /// Aggregate: connected iff at least one device-link is connected.
    private(set) var connection: Connection = .offline

    /// Per-device status. Empty if config has no usable devices.
    private(set) var deviceStatuses: [DeviceStatus] = []

    private let config: Config
    private var hidLinks: [HIDLink] = []
    private let layoutWatcher: LayoutWatcher

    init(config: Config) {
        self.config = config
        layoutWatcher = LayoutWatcher(layouts: config.layouts)
    }

    /// Wires up the watchers and opens HID links for every usable device in
    /// the config. Call once after init, on the main actor.
    func start() {
        layoutWatcher.onLayoutChanged = { [weak self] idx in
            guard let self else { return }
            layoutIndex = idx
            for link in hidLinks {
                link.send(layoutIndex: idx)
            }
        }
        layoutWatcher.start()
        buildAndStartLinks()
    }

    /// Tears down all HID links and rebuilds them. Wired to the "Reconnect"
    /// menubar button: lets users recover after killing a conflicting daemon
    /// (typically qmk-hid-host) without restarting the whole app.
    func reconnectAll() {
        for link in hidLinks {
            link.stop()
        }
        hidLinks = []
        buildAndStartLinks()
    }

    private func buildAndStartLinks() {
        let resolved = config.devices.compactMap(ResolvedDevice.init)
        if resolved.isEmpty {
            Log.app.error("no usable device in config — running in observe-only mode")
            hidLinks = []
            deviceStatuses = []
            connection = .offline
            return
        }

        hidLinks = resolved.map(HIDLink.init)
        deviceStatuses = resolved.map { dev in
            DeviceStatus(
                id: dev.productId,
                name: dev.name,
                productId: dev.productId,
                state: .offline,
                offlineReason: .awaitingDevice
            )
        }

        for link in hidLinks {
            link.onStateChange = { [weak self, weak link] newState in
                guard let self, let link else { return }
                guard let idx = hidLinks.firstIndex(where: { $0 === link }) else { return }
                handleLinkStateChange(idx: idx, state: newState)
            }
            link.start()
        }
    }

    private func handleLinkStateChange(idx: Int, state: HIDLink.State) {
        guard idx < deviceStatuses.count else { return }
        deviceStatuses[idx].state = state
        deviceStatuses[idx].offlineReason = hidLinks[idx].offlineReason

        let anyConnected = deviceStatuses.contains {
            if case .connected = $0.state { return true }
            return false
        }
        connection = anyConnected ? .connected : .offline

        // On per-device connect, push two packets in order:
        //   1. _OS_TYPE (MAC) — so firmware that knows 0xB0 flips into its
        //      macOS-Russian variant before the first layout arrives.
        //   2. _LAYOUT — last known layout, so the firmware doesn't sit on
        //      a stale pre-disconnect state.
        // Firmware that doesn't know 0xB0 ignores it; layout still works.
        if case .connected = state {
            hidLinks[idx].sendOSFlag()
            if let last = layoutWatcher.lastIndex {
                hidLinks[idx].send(layoutIndex: last)
            }
        }
    }
}

// MARK: - Display helpers

extension AppModel {
    /// Short language label (`EN`, `RU`, or `—` when status is unknown).
    var languageLabel: String {
        switch layoutIndex {
        case .some(0): "EN"
        case .some: "RU"
        case .none: "—"
        }
    }

    /// Top-level human-readable status — used when there's a single device or
    /// no devices, otherwise the UI iterates `deviceStatuses` directly.
    var connectionDescription: String {
        if deviceStatuses.isEmpty {
            return "No device configured"
        }
        if deviceStatuses.count == 1, let status = deviceStatuses.first {
            return status.summary
        }
        let connectedCount = deviceStatuses.filter {
            if case .connected = $0.state { return true }
            return false
        }.count
        return "\(connectedCount) of \(deviceStatuses.count) connected"
    }
}

extension AppModel.DeviceStatus {
    /// e.g. "Corne — connected" / "Corne — device busy (qmk-hid-host running?)".
    var summary: String {
        switch state {
        case .connected:
            "\(name) — connected"
        case .offline:
            "\(name) — \((offlineReason ?? .awaitingDevice).menuLabel.lowercasedFirstLetter())"
        }
    }

    var productIdLabel: String {
        String(format: "0x%04X", productId)
    }
}

// MARK: - String helper

private extension String {
    /// Lowercases the first character. Used to splice `OfflineReason.menuLabel`
    /// ("Not connected") into a sentence after "—" without double-capitalising.
    func lowercasedFirstLetter() -> String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}

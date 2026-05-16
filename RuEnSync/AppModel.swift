import Foundation
import Observation

// MARK: - AppModel

/// Top-level reactive state shared by the menubar UI and the background
/// watchers. Owned by `RuEnSyncApp`, observed by `MenuBarExtra` content.
@MainActor
@Observable
final class AppModel {
    /// One row per configured device. Order matches `config.devices`. The
    /// menubar renders one line per status.
    struct DeviceStatus: Equatable, Identifiable {
        /// Array index in `config.devices`. Used as `Identifiable.id` so
        /// SwiftUI ForEach stays well-defined when two devices share a
        /// `productId` (e.g. a matched pair of identical keyboards).
        let id: Int
        let name: String
        let productId: UInt32
        var state: HIDLink.State
    }

    /// 0 = EN, anything else = RU (firmware convention). `nil` until the
    /// first layout read.
    private(set) var layoutIndex: UInt8?

    /// Per-device status. Empty if config has no usable devices.
    private(set) var deviceStatuses: [DeviceStatus] = []

    /// Recent events, newest first. UI binds to this for the activity panel.
    let activity = ActivityStore()

    private let config: Config
    private var hidLinks: [HIDLink] = []
    private let layoutWatcher: LayoutWatcher

    /// Background task that retries `reconnectAll()` while any link is offline
    /// for a recoverable reason. `nil` when no retry is pending. Cancelled the
    /// moment any link transitions back to `.connected`.
    private var reconnectTask: Task<Void, Never>?
    /// Consecutive retry attempts since the last successful connect. Reset on
    /// `.connected`. Passed to `retryDelay(attempt:)` so the policy can apply
    /// backoff if it wants.
    private var reconnectAttempt: Int = 0

    init(config: Config) {
        self.config = config
        layoutWatcher = LayoutWatcher(layouts: config.layouts)
    }

    /// Wires up the watchers and opens HID links for every usable device in
    /// the config. Call once after init, on the main actor.
    func start() {
        layoutWatcher.onLayoutChanged = { [weak self] idx in
            guard let self else { return }
            let previous = layoutIndex
            layoutIndex = idx
            if previous != idx {
                activity.record(.layoutChanged(label: idx == 0 ? "EN" : "RU"))
            }
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
        activity.record(.reconnectTriggered)
        for link in hidLinks {
            link.stop()
        }
        hidLinks = []
        buildAndStartLinks()
    }

    /// Spawns the background task that keeps retrying `reconnectAll()` until
    /// any link reports `.connected`. Idempotent: a no-op if a task is already
    /// running. Cancellation is the only termination path — the closure inside
    /// the task watches `reconnectAttempt` (mutated on the main actor) and
    /// `Task.isCancelled` to know when to stop.
    private func scheduleReconnectTask() {
        if reconnectTask != nil { return }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let attempt = await self?.reconnectAttempt else { return }
                let delay = Self.retryDelay(attempt: attempt)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return // cancelled mid-sleep
                }
                guard !Task.isCancelled else { return }
                await self?.bumpReconnectAttemptAndRetry()
            }
        }
    }

    private func cancelReconnectTask() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Main-actor-isolated helper called from inside `reconnectTask`. Increments
    /// the attempt counter and triggers a full link rebuild. The counter is
    /// only reset on a successful `.connected` transition.
    private func bumpReconnectAttemptAndRetry() {
        reconnectAttempt += 1
        reconnectAll()
    }

    /// Computes the delay before the **next** reconnect attempt.
    ///
    /// Exponential backoff: 0.5s · 2^attempt, capped at 30s. Schedule by
    /// attempt: 0.5s, 1s, 2s, 4s, 8s, 16s, then 30s forever. Quick on the
    /// common transient (Vial open for a moment, USB burst), gentle once
    /// stuck (Vial held open through an editing session). Counter resets on
    /// `.connected`, so a recovered outage never drags the next one's first
    /// retry to the cap.
    private static func retryDelay(attempt: Int) -> Duration {
        let baseMS = 500
        let capMS = 30000
        let exponent = min(max(attempt, 0), 10)
        let delayMS = baseMS * (1 << exponent)
        return .milliseconds(min(delayMS, capMS))
    }

    private func buildAndStartLinks() {
        let resolved = config.devices.compactMap(ResolvedDevice.init)
        if resolved.isEmpty {
            Log.app.error("no usable device in config — running in observe-only mode")
            hidLinks = []
            deviceStatuses = []
            return
        }

        hidLinks = resolved.map(HIDLink.init)
        deviceStatuses = resolved.enumerated().map { idx, dev in
            DeviceStatus(
                id: idx,
                name: dev.name,
                productId: dev.productId,
                state: .offline(reason: .awaitingDevice)
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
        guard idx < deviceStatuses.count, idx < hidLinks.count else {
            let statusesCount = deviceStatuses.count
            let linksCount = hidLinks.count
            Log.app
                .fault(
                    "handleLinkStateChange out-of-bounds: idx=\(idx) statuses=\(statusesCount) links=\(linksCount)"
                )
            return
        }
        let previousState = deviceStatuses[idx].state
        deviceStatuses[idx].state = state

        let name = deviceStatuses[idx].name
        switch (previousState, state) {
        case (.offline, .connected):
            activity.record(.deviceConnected(name: name))
            cancelReconnectTask()
            reconnectAttempt = 0
        case let (.connected, .offline(reason)):
            activity.record(.deviceDisconnected(name: name, reason: reason.menuLabel))
            if reason.isRecoverable {
                scheduleReconnectTask()
            }
        case let (.offline(prev), .offline(now)) where prev != now:
            activity.record(.deviceOfflineReasonChanged(name: name, reason: now.menuLabel))
            if now.isRecoverable, reconnectTask == nil {
                scheduleReconnectTask()
            }
        default:
            break
        }

        // On per-device connect, push two packets in order:
        //   1. _OS_TYPE (MAC) — so firmware that knows 0xB0 flips into its
        //      macOS-Russian variant before the first layout arrives.
        //   2. _LAYOUT — last known layout, so the firmware doesn't sit on
        //      a stale pre-disconnect state.
        // Firmware that doesn't know 0xB0 ignores it; layout still works.
        if case .connected = state {
            let osOK = hidLinks[idx].sendOSFlag()
            if !osOK {
                // sendReport already logged the IOReturn at .error. .fault
                // here so it surfaces in Console for users who didn't filter
                // to .info/.debug; the headline feature of this app
                // (auto-flip MAC mode after reflash) silently degrades into
                // "you must press the on-keyboard toggle".
                Log.hid
                    .fault(
                        "OS handshake failed for \(name, privacy: .public) — firmware will run in default (non-MAC) mode until reconnect"
                    )
                activity.record(.osHandshakeFailed(name: name))
                return
            }
            activity.record(.osHandshakeSent(name: name))
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

    /// True iff any configured device is currently connected. Derived from
    /// `deviceStatuses`; no shadow field to keep in sync.
    var isAnyDeviceConnected: Bool {
        deviceStatuses.contains { if case .connected = $0.state { true } else { false } }
    }

    /// Top-level human-readable status — used when there's a single device or
    /// no devices, otherwise the UI iterates `deviceStatuses` directly.
    var connectionDescription: String {
        Self.describe(deviceStatuses)
    }

    /// Pure, testable formatter for the aggregate status line.
    static func describe(_ statuses: [DeviceStatus]) -> String {
        if statuses.isEmpty {
            return "No device configured"
        }
        if statuses.count == 1, let status = statuses.first {
            return status.summary
        }
        let connectedCount = statuses.count(where: {
            if case .connected = $0.state { return true }
            return false
        })
        return "\(connectedCount) of \(statuses.count) connected"
    }
}

extension AppModel.DeviceStatus {
    /// e.g. "Corne — connected" / "Corne — device busy (qmk-hid-host running?)".
    var summary: String {
        switch state {
        case .connected:
            "\(name) — connected"
        case let .offline(reason):
            "\(name) — \(reason.menuLabel.lowercasedFirstLetter())"
        }
    }

    var productIdLabel: String {
        String(format: "0x%04X", productId)
    }
}

// MARK: - String helper

extension String {
    /// Lowercases the first character. Used to splice `OfflineReason.menuLabel`
    /// ("Not connected") into a sentence after "—" without double-capitalising.
    func lowercasedFirstLetter() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

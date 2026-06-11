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
    /// Writer is `internal` (not `private(set)`) so the coordination
    /// extension in another file can mutate; we keep the convention of
    /// writing through AppModel methods to preserve the @Observable contract.
    var deviceStatuses: [DeviceStatus] = [] {
        didSet {
            deviceStatusesDict = [:]
            for status in deviceStatuses {
                deviceStatusesDict[status.productId] = status.state
            }
        }
    }

    /// Dictionary representation of `deviceStatuses` for O(1) lookups.
    /// Kept in sync with `deviceStatuses` via `didSet`.
    private(set) var deviceStatusesDict: [UInt32: HIDLink.State] = [:]

    /// Name of the conflicting app we've yielded the HID device to, or `nil`
    /// when we're operating normally. While non-nil all HID links are stopped
    /// and no reconnect attempts are scheduled — we sit out until the app
    /// quits and ConflictWatcher fires `onConflictCleared`.
    var yieldedTo: String?

    /// Last surfacable error to show in the Settings window as an inline
    /// banner — disk-full saves, corrupt config detected, etc. `nil` when
    /// nothing is wrong. Cleared by the UI once the user has seen it.
    /// Surfaced here (not just logged) because the user has no other way to
    /// know that their edit didn't take.
    var lastSettingsError: String?

    /// Recent events, newest first. UI binds to this for the activity panel.
    let activity = ActivityStore()

    /// Ring-buffer of recent HID writes, surfaced by the Debug → HID
    /// Inspector window. Bound to `Config.Debug.hidInspector` — empty when
    /// the flag is off.
    let packetLog = HIDPacketLog()

    // `internal` access (not `private`) so the coordination extension in
    // AppModel+Coordination.swift can read/write these. Swift's `private`
    // is per-type-per-file; extensions across files need at least internal.
    var config: Config
    var hidLinks: [HIDLink] = []
    let layoutWatcher: LayoutWatcher
    let conflictWatcher = ConflictWatcher()
    let appContextWatcher = AppContextWatcher()
    let sleepWatcher = SleepWatcher()
    /// Held to keep the file-watcher alive — releasing it would cancel
    /// the DispatchSource and stop reloads.
    var configWatch: DispatchSourceFileSystemObject?

    /// Background task that retries `reconnectAll()` while any link is offline
    /// for a recoverable reason. `nil` when no retry is pending. Cancelled the
    /// moment any link transitions back to `.connected`.
    private var reconnectTask: Task<Void, Never>?
    /// Consecutive retry attempts since the last successful connect. Reset on
    /// `.connected`. Passed to `retryDelay(attempt:)` so the policy can apply
    /// backoff if it wants.
    private var reconnectAttempt: Int = 0

    /// When false, `start()` skips the first-run auto-discovery seed. We use
    /// this when the config file is present but failed to decode: discovering
    /// devices then would call `ConfigStore.save`, which would overwrite the
    /// recoverable bad file with an empty shell and silently lose all of the
    /// user's existing rules / device names / debug settings.
    private let allowAutoDiscoverySeed: Bool

    init(config: Config, allowAutoDiscoverySeed: Bool = true) {
        self.config = config
        self.allowAutoDiscoverySeed = allowAutoDiscoverySeed
        layoutWatcher = LayoutWatcher(layouts: config.layouts)
    }

    /// Wires up the watchers and opens HID links for every usable device in
    /// the config. Call once after init, on the main actor.
    func start() {
        setupLayoutWatcher()
        setupConflictWatcher()
        setupAppContextWatcher()
        setupSleepWatcher()
        setupConfigWatch()
        runAutoDiscoveryIfNeeded()

        if yieldedTo == nil {
            buildAndStartLinks()
        }
    }

    private func setupLayoutWatcher() {
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
    }

    private func setupConflictWatcher() {
        // Conflict watcher is started BEFORE buildAndStartLinks so that an
        // already-running Vial/QMK Toolbox seeds `yieldedTo` synchronously
        // (handleConflictAppeared runs from inside conflictWatcher.start()
        // when the seed scan finds a running app). We then skip the initial
        // buildAndStartLinks(); resume happens later via onConflictCleared.
        conflictWatcher.onConflictAppeared = { [weak self] name in
            self?.handleConflictAppeared(appName: name)
        }
        conflictWatcher.onConflictCleared = { [weak self] in
            self?.handleConflictCleared()
        }
        conflictWatcher.start()
    }

    private func setupAppContextWatcher() {
        appContextWatcher.onAppActivated = { [weak self] bundleId in
            // Watcher already filters nil bundle IDs internally; the
            // remaining check inside `handleAppActivated` is for the
            // master-switch and rule-presence guards.
            self?.handleAppActivated(bundleId: bundleId)
        }
        appContextWatcher.start()
    }

    private func setupSleepWatcher() {
        // Wake-from-sleep recovery; rationale + flow live on `handleDidWake`.
        sleepWatcher.onDidWake = { [weak self] in
            self?.handleDidWake()
        }
        sleepWatcher.start()
    }

    private func setupConfigWatch() {
        configWatch = ConfigStore.watch { [weak self] result in
            self?.handleConfigEvent(result)
        }
    }

    private func runAutoDiscoveryIfNeeded() {
        // First-time auto-discovery: if `devices` is empty AND we've never
        // run the scanner before, run it now and seed config with whatever
        // we find. The flag prevents resurrecting devices a user later
        // removes on purpose — without it, deleting the last device would
        // immediately re-add it on the next launch.
        //
        // Suppressed entirely when the initial load was corrupt: writing a
        // discovered-devices shell over a recoverable bad file would erase
        // the user's intent.
        if allowAutoDiscoverySeed,
           config.devices.isEmpty,
           !UserDefaults.standard.bool(forKey: Self.autoDiscoveryRanKey)
        {
            // Only mark "ran" if the save succeeded — otherwise next launch
            // should retry instead of stranding the user with empty devices
            // and a UserDefaults flag that prevents any further attempt.
            if autoDiscoverDevices() {
                UserDefaults.standard.set(true, forKey: Self.autoDiscoveryRanKey)
            }
        }
    }

    /// UserDefaults key for the first-run auto-discovery flag. Public so a
    /// future Settings "Re-run auto-discovery" button can clear it.
    static let autoDiscoveryRanKey = "ruensync.autoDiscoveryRan"

    /// Tears down all HID links and rebuilds them. Wired to the "Reconnect"
    /// menubar button: lets users recover after killing a conflicting daemon
    /// (typically qmk-hid-host) without restarting the whole app.
    ///
    /// While `yieldedTo != nil` this is a no-op except for the activity
    /// record — manual reconnect while paused for Vial would just race the
    /// running Vial and lose. Users wanting to forcibly retake the device
    /// must use `forceResume()` (which clears `yieldedTo` first).
    func reconnectAll() {
        activity.record(.reconnectTriggered)
        if let yielded = yieldedTo {
            // Bind to local to avoid the swiftformat "remove redundant self"
            // pass eating the `self.yieldedTo` that Logger's @autoclosure
            // requires inside an escaping context.
            Log.app.info("reconnect ignored — yielded to \(yielded, privacy: .public)")
            return
        }
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

    /// internal so AppModel+Coordination can cancel before yielding.
    func cancelReconnectTask() {
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

    /// internal so AppModel+Coordination can rebuild after resume/config change.
    func buildAndStartLinks() {
        // Walk the config explicitly (rather than `compactMap`) so each
        // unparseable productId is logged and surfaced — otherwise a typo
        // in config.json yields a permanently-dead row with no breadcrumb.
        var resolved: [ResolvedDevice] = []
        var invalidNames: [String] = []
        for device in config.devices {
            if let r = ResolvedDevice(device) {
                resolved.append(r)
            } else {
                invalidNames.append(device.name)
                Log.config
                    .error(
                        "skipping device \"\(device.name, privacy: .public)\" — invalid productId \(device.productId, privacy: .public)"
                    )
            }
        }
        // Surface ONCE — only re-pop if the user dismissed and the
        // banner slot is currently empty. Avoids spamming the banner
        // on every reconnect/config-reload while bad rows persist.
        if !invalidNames.isEmpty, lastSettingsError == nil {
            let joined = invalidNames.joined(separator: ", ")
            lastSettingsError = String(
                localized: "Skipped device(s) with invalid productId: \(joined). Fix or remove them in Settings → Devices."
            )
        }
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

        let inspectionEnabled = config.effectiveHidInspectorEnabled
        for link in hidLinks {
            link.packetLog = packetLog
            link.inspectionEnabled = inspectionEnabled
            link.onStateChange = { [weak self, weak link] newState in
                guard let self, let link else { return }
                guard let idx = hidLinks.firstIndex(where: { $0 === link }) else { return }
                handleLinkStateChange(idx: idx, state: newState)
            }
            link.start()
        }
    }

    /// Re-applies the `hidInspector` flag to every live HID link. Called
    /// from the coordination extension after a config reload so toggling
    /// `"debug": { "hidInspector": true }` in config.json takes effect
    /// without needing to reconnect (which would interrupt typing).
    func refreshInspectionFlag() {
        let enabled = config.effectiveHidInspectorEnabled
        for link in hidLinks {
            link.inspectionEnabled = enabled
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
            // Force a fresh TIS read so the firmware seed reflects the actual
            // current macOS layout, not a possibly-stale `lastIndex` left over
            // from a missed notification (Punto Switcher burst, distributed-
            // notification coalescing, etc.). Without this, manual Reconnect
            // would silently re-send the stale value and the desync would
            // outlive the recovery.
            layoutWatcher.refreshCurrentIndex()
            if let last = layoutWatcher.lastIndex {
                hidLinks[idx].send(layoutIndex: last)
            }
        }
    }
}

// Display helpers (`languageLabel`, `DeviceStatus.summary`, …) live in
// `AppModel+Display.swift` to keep this file under the 400-line lint cap.

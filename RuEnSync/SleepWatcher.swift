import AppKit
import Foundation

// MARK: - SleepWatcher

/// Watches macOS wake-from-sleep transitions via `NSWorkspace.didWakeNotification`.
///
/// Why it exists: when the Mac sleeps, `DistributedNotificationCenter`
/// deliveries are coalesced and some `kTISNotifySelectedKeyboardInputSourceChanged`
/// notifications get silently dropped across the sleep boundary. USB HID may
/// also suspend/resume without firing a clean removal+added pair through IOKit.
/// The net effect: host-side `lastIndex` and the firmware's `cur_lang` can
/// diverge, so the user wakes the Mac, types a key, and gets the wrong layout
/// until they manually click "Reconnect" or restart the app.
///
/// `onDidWake` is the single hook the owner reacts to. `AppModel` reuses the
/// existing manual-reconnect path (`reconnectAll`) from there, which goes
/// through `.connected` → fresh TIS refresh + OS handshake + layout packet —
/// the same recovery sequence the user used to invoke by hand.
///
/// Threading: `NSWorkspace.shared.notificationCenter` posts on an arbitrary
/// thread; we hop to main via `queue: .main` and `MainActor.assumeIsolated`.
/// Same `assumeIsolated` pattern documented in CLAUDE.md §3 (originally
/// applied to DistributedNotificationCenter), here adapted to NSWorkspace.
@MainActor
final class SleepWatcher {
    /// Fired on every `didWakeNotification`. Owner decides what to do.
    var onDidWake: (() -> Void)?

    private var didWakeToken: NSObjectProtocol?
    private var hasStarted = false

    func start() {
        if hasStarted { return }
        hasStarted = true

        let center = NSWorkspace.shared.notificationCenter
        didWakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.app.info("SleepWatcher: didWakeNotification")
                self?.onDidWake?()
            }
        }
        Log.app.info("SleepWatcher started")
    }

    /// Explicit cleanup. Owner (AppModel) is app-lifetime today so `stop()`
    /// is rarely called outside tests; we still provide it because Swift 6
    /// `deinit` cannot touch the non-Sendable token (CLAUDE.md §2).
    func stop() {
        if let didWakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeToken)
            self.didWakeToken = nil
        }
        hasStarted = false
    }
}

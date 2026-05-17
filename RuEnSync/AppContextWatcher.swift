import AppKit
import Foundation
import os

// MARK: - AppContextWatcher

/// Observes which macOS application is currently frontmost and fires a
/// callback with its bundle identifier, with debounce. Used by AppModel to
/// look up per-app layout rules and request a programmatic input-source
/// switch via LayoutWatcher.
///
/// Debounce rationale: `didActivateApplicationNotification` fires multiple
/// times during a single user gesture — Cmd+Tab through the app switcher,
/// Mission Control transitions, Spotlight dismissals all emit intermediate
/// activations within tens of milliseconds. Without debounce we'd dispatch
/// TIS calls for every passing app, which both wastes work and confuses the
/// user (brief flickers of "wrong" layout). 200 ms is a typical Cmd+Tab
/// settling time and well under any human-perceptible delay.
///
/// Threading: same pattern as ConflictWatcher — extract Sendable primitives
/// inside the @Sendable `addObserver` closure before crossing into
/// `MainActor.assumeIsolated`. See CLAUDE.md §3.
@MainActor
final class AppContextWatcher {
    /// Fires after the debounce window has elapsed, with the bundle ID of
    /// the app that is currently frontmost. The watcher filters out the
    /// no-bundle-ID case internally (background helpers) so consumers
    /// don't have to repeat the `guard let bundleId` check.
    var onAppActivated: ((_ bundleId: String) -> Void)?

    /// Debounce interval. 200 ms is a tunable; if Cmd+Tab feels laggy we
    /// can drop to 100 ms, if it spams we can go to 300 ms.
    nonisolated static let debounce: Duration = .milliseconds(200)

    private var observerToken: NSObjectProtocol?
    private var pendingDispatch: Task<Void, Never>?
    private var hasStarted = false

    func start() {
        if hasStarted { return }
        hasStarted = true

        let center = NSWorkspace.shared.notificationCenter
        observerToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                self?.scheduleDispatch(bundleId: bundleId)
            }
        }

        // Seed with the current frontmost app so that opening RuEnSync while
        // already focused inside (say) Slack immediately applies the Slack
        // rule, without waiting for the next Cmd+Tab.
        let initial = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        scheduleDispatch(bundleId: initial)
        Log.app.info("AppContextWatcher started")
    }

    func stop() {
        pendingDispatch?.cancel()
        pendingDispatch = nil
        if let observerToken {
            NSWorkspace.shared.notificationCenter.removeObserver(observerToken)
            self.observerToken = nil
        }
        hasStarted = false
    }

    /// Replaces any in-flight dispatch with a new one. Net effect: a burst of
    /// 5 activations within `debounce` collapses into a single callback for
    /// the **last** app. Task-based debounce instead of DispatchSourceTimer
    /// because we already need `@MainActor` isolation for the callback, and
    /// `Task.sleep` is cheap.
    ///
    /// `nil` bundle IDs (background helpers without an Info.plist
    /// `CFBundleIdentifier`) are dropped here so the consumer doesn't have
    /// to repeat the guard — there's no useful per-app rule for "the
    /// unnamed thing macOS just focused".
    private func scheduleDispatch(bundleId: String?) {
        pendingDispatch?.cancel()
        guard let bundleId else { return }
        pendingDispatch = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.debounce)
            } catch is CancellationError {
                return // a newer activation superseded us
            } catch {
                Log.app.error("AppContextWatcher sleep failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !Task.isCancelled else { return }
            self?.onAppActivated?(bundleId)
        }
    }
}

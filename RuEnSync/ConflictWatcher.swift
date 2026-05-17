import AppKit
import Foundation
import os

// MARK: - ConflictWatcher

/// Watches for launches/terminations of applications that hold exclusive
/// access to the QMK Raw HID interface — typically Vial and QMK Toolbox.
/// When any of them launches we ask AppModel to release the device so the
/// user can flash/configure without two daemons racing for the endpoint.
/// When the last conflicting app exits we resume normal operation.
///
/// Threading: `NSWorkspace.shared.notificationCenter` delivers notifications
/// on an arbitrary thread; we explicitly post the callbacks onto the main
/// queue so AppModel's `@MainActor` invariants hold. Mirrors the pattern in
/// `LayoutWatcher.start()` (queue: `.main` + `MainActor.assumeIsolated`).
@MainActor
final class ConflictWatcher {
    /// Bundle IDs of apps whose exclusive access conflicts with ours.
    /// Comparing by bundle ID rather than display name avoids locale issues
    /// (Vial localizes its Finder name in some installs) and impersonation
    /// (any process can name itself "Vial", but bundle IDs are signed).
    ///
    /// Confirm the actual bundle identifiers on this machine with:
    ///   osascript -e 'id of app "Vial"'
    ///   osascript -e 'id of app "QMK Toolbox"'
    nonisolated static let conflictingBundleIds: Set<String> = [
        "today.vial",
        "fm.qmk.toolbox",
    ]

    /// Fired when the first conflicting app appears (either launches now or
    /// was already running when we started). Carries the human-readable app
    /// name for the activity log / UI.
    var onConflictAppeared: ((_ appName: String) -> Void)?

    /// Fired when the last conflicting app disappears.
    var onConflictCleared: (() -> Void)?

    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?
    private var hasStarted = false

    /// Bundle IDs of conflicting apps currently believed to be running. We
    /// track the full set, not just "any active", so that closing one of two
    /// conflicting apps does NOT trigger resume while the other still holds
    /// the device.
    private var activeBundleIds: Set<String> = []

    func start() {
        if hasStarted { return }
        hasStarted = true

        // Seed `activeBundleIds` from already-running apps so we yield
        // before HIDLink.start() ever tries to open the busy endpoint.
        var seedName: String?
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleId = app.bundleIdentifier,
                  Self.conflictingBundleIds.contains(bundleId) else { continue }
            if activeBundleIds.isEmpty {
                seedName = app.localizedName ?? Self.fallbackDisplayName(for: bundleId)
            }
            activeBundleIds.insert(bundleId)
        }

        if let seedName {
            onConflictAppeared?(seedName)
        }

        let center = NSWorkspace.shared.notificationCenter
        launchToken = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable primitives before crossing the actor border —
            // `Notification` and `NSRunningApplication` are non-Sendable, so
            // passing them into `assumeIsolated` is a Swift 6 data-race
            // diagnostic even though `.main` queue guarantees we're on the
            // main thread already. See CLAUDE.md §3 for the parallel pattern
            // in LayoutWatcher.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            let localizedName = app?.localizedName
            MainActor.assumeIsolated {
                self?.handleLaunched(bundleId: bundleId, localizedName: localizedName)
            }
        }
        terminateToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleTerminated(bundleId: bundleId)
            }
        }
        Log.app
            .info("ConflictWatcher started — watching \(Self.conflictingBundleIds.count, privacy: .public) bundle IDs")
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let launchToken { center.removeObserver(launchToken) }
        if let terminateToken { center.removeObserver(terminateToken) }
        launchToken = nil
        terminateToken = nil
        hasStarted = false
    }

    private func handleLaunched(bundleId: String?, localizedName: String?) {
        guard let bundleId, Self.conflictingBundleIds.contains(bundleId) else { return }

        let wasEmpty = activeBundleIds.isEmpty
        activeBundleIds.insert(bundleId)
        guard wasEmpty else { return } // already yielded; nothing to do

        let name = localizedName ?? Self.fallbackDisplayName(for: bundleId)
        Log.app.info("conflicting app launched: \(name, privacy: .public)")
        onConflictAppeared?(name)
    }

    private func handleTerminated(bundleId: String?) {
        guard let bundleId, activeBundleIds.contains(bundleId) else { return }

        activeBundleIds.remove(bundleId)
        guard activeBundleIds.isEmpty else { return } // another conflicting app still running

        Log.app.info("last conflicting app terminated — resuming")
        onConflictCleared?()
    }

    /// Hard-coded fallback when `NSRunningApplication.localizedName` is nil
    /// (rare — happens during the brief window after launch before AppKit has
    /// populated the metadata). Keep in sync with `conflictingBundleIds`.
    private static func fallbackDisplayName(for bundleId: String) -> String {
        switch bundleId {
        case "today.vial": "Vial"
        case "fm.qmk.toolbox": "QMK Toolbox"
        default: bundleId
        }
    }
}

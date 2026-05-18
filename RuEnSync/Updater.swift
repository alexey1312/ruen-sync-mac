import AppKit
import Combine
import Foundation
import Sparkle

// MARK: - Updater

/// Thin wrapper around `SPUStandardUpdaterController`. We keep one of these
/// alive for the lifetime of the app and expose the underlying `SPUUpdater`
/// to the menu UI. Sparkle is the system of record — we don't shadow its
/// state. The view model below republishes `canCheckForUpdates` so the
/// "Check for Updates…" item can disable itself while a check is in flight.
@MainActor
final class Updater {
    let controller: SPUStandardUpdaterController
    /// The user-driver delegate has to outlive every Sparkle update session,
    /// and `SPUStandardUpdaterController` only weakly references it. Storing
    /// it on `Updater` keeps it alive for the lifetime of the app.
    private let userDriverDelegate = SparkleUserDriverDelegate()

    init() {
        // `startingUpdater: true` kicks off the scheduled-check timer
        // immediately. Combined with `SUEnableAutomaticChecks=true` in
        // Info.plist, users get a quiet check at launch and then every
        // `SUScheduledCheckInterval` seconds (24h by default).
        //
        // `userDriverDelegate` is the LSUIElement workaround: Sparkle's
        // documented default for background apps is to surface the update
        // alert immediately but BEHIND other windows (the user never sees
        // it). See `SparkleUserDriverDelegate` for the policy-flip dance.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
        // os.Logger's interpolation is autoclosure-based, so referencing a
        // stored property here triggers the Swift 6 "explicit self" rule.
        let feed = controller.updater.feedURL?.absoluteString ?? "<nil>"
        Log.app.info("Updater initialised — feed=\(feed, privacy: .public)")
    }

    var updater: SPUUpdater {
        controller.updater
    }

    func checkForUpdates() {
        // Belt-and-braces: SparkleUserDriverDelegate switches activation
        // policy when an actual update appears, but a manual "Check for
        // Updates…" from the menubar should also raise the menubar-app's
        // sheet to the front even when there are NO updates (Sparkle then
        // shows a "You're up to date" alert). Doing the activate here, in
        // addition to the delegate-side hook, covers both branches without
        // depending on Sparkle's internal call order.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

// MARK: - SparkleUserDriverDelegate

/// Implements `SPUStandardUserDriverDelegate` so Sparkle's update prompts
/// surface IN FRONT of other apps on this LSUIElement (menubar-only) build,
/// instead of opening behind whichever window is currently key.
///
/// Sparkle's own documentation calls out the symptom: "For background
/// applications, the driver typically shows the update alert immediately
/// but behind other windows." The recommended workaround is to flip
/// `NSApp.activationPolicy` from `.accessory` to `.regular` for the duration
/// of the update session, then back to `.accessory` once Sparkle is done.
/// `LSUIElement=true` in Info.plist sets the initial policy; the runtime
/// `setActivationPolicy` calls below toggle it transiently.
///
/// `@unchecked Sendable` because we don't store any mutable state — every
/// method just talks to `NSApp`. Sparkle's `SPUStandardUserDriverDelegate`
/// is an Objective-C protocol whose methods have no Swift actor isolation,
/// so we use `MainActor.assumeIsolated` to bridge to AppKit; Sparkle's
/// documentation guarantees these are dispatched on the main thread, which
/// makes the assumption sound. Mirrors the pattern in `LayoutWatcher` and
/// `ConflictWatcher` (see CLAUDE.md §3).
final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate, @unchecked Sendable {
    /// Tells Sparkle this driver wants the "gentle" path — without this,
    /// Sparkle on macOS 13+ may surface scheduled-update alerts behind the
    /// active window for LSUIElement apps without giving us a delegate hook
    /// to react to.
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Called when an update is found and Sparkle is about to present it.
    /// Promote to regular app so the window can come to front. `activate`
    /// is a no-op if the app is already frontmost — safe for user-initiated
    /// checks too (where activate() already ran in `Updater.checkForUpdates`).
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Called before Sparkle shows a modal alert (e.g. "You're up to date",
    /// errors). The alert window inherits activation from the app — without
    /// this, manual checks against the up-to-date branch surface invisibly.
    func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Revert to menubar-only mode after Sparkle's user-session ends so the
    /// Dock icon doesn't linger after the user dismisses the alert. The
    /// install-and-relaunch path quits before this fires, so we don't need
    /// to do anything special for that branch.
    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - View model

/// SwiftUI bridge for Sparkle's KVO-based `canCheckForUpdates`. Sparkle still
/// uses `ObservableObject`/Combine because its public API predates the
/// Observation framework; bridging through `@Published` keeps the menu item's
/// `.disabled(...)` reactive without polluting `AppModel`.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        // `assign(to: &$published)` writes straight into the @Published
        // storage and manages the subscription's lifetime itself. The more
        // general `assign(to:on:)` would have captured `self` strongly and
        // — combined with `self` owning the AnyCancellable — leaked the
        // view model on every instantiation.
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

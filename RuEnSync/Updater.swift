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
        // `userDriverDelegate` is the LSUIElement workaround — see
        // `SparkleUserDriverDelegate` for the activation-policy dance.
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
        // Activate explicitly: the delegate's policy-flip path is invoked
        // only when Sparkle is about to surface UI. For a manual check we
        // want the menubar UI to come up immediately, including the
        // "You're up to date" alert branch which doesn't always route
        // through `willShowModalAlert` on every Sparkle build.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

// MARK: - SparkleUserDriverDelegate

/// Implements `SPUStandardUserDriverDelegate` so Sparkle's update prompts
/// surface IN FRONT of other apps on this LSUIElement (menubar-only) build,
/// instead of opening behind whichever window is currently key.
///
/// Background: Sparkle's
/// [SPUStandardUserDriverDelegate docs][1] note that for `.accessory`-style
/// background apps the standard driver presents the update alert
/// "immediately but behind other windows". The recommended workaround is
/// to flip `NSApp.activationPolicy` from `.accessory` to `.regular` for
/// the duration of the update session and revert when Sparkle calls back
/// `standardUserDriverWillFinishUpdateSession`.
///
/// [1]: https://sparkle-project.org/documentation/api-reference/Protocols/SPUStandardUserDriverDelegate.html
///
/// Threading: `SPUStandardUserDriverDelegate` is an Objective-C protocol —
/// methods inherit no Swift actor isolation. Sparkle dispatches these on
/// the main thread in practice, but the contract isn't formal. The
/// `runOnMain` helper below survives a hypothetical off-main call without
/// crashing the process: it dispatches and logs at `.error` instead of
/// abort-via-`assumeIsolated`. Same idea as the NSWorkspace pattern in
/// CLAUDE.md §3, applied to AppKit instead of DistributedNotificationCenter.
///
/// State: `revertTask` is a watchdog. Every promote schedules a Task that
/// forces `.accessory` after `watchdogTimeout` if Sparkle never calls
/// `willFinishUpdateSession` (network error mid-download, force-quit, crash
/// inside Sparkle's pipeline). Without the watchdog the Dock icon could
/// linger forever after a half-completed update flow. Tasks are cancelled
/// on every subsequent promote and on the legitimate finish path.
///
/// `@unchecked Sendable` is the honest annotation: `SPUStandardUpdaterController`
/// stores its `userDriverDelegate` parameter, so the bridge needs the class
/// to be `Sendable`. We DO have mutable state (`revertTask`) but it's
/// `@MainActor`-isolated; cross-actor accidental access would fail the type
/// check at the call site. `@unchecked` waives the audit; the isolation is
/// what enforces correctness.
final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate, @unchecked Sendable {
    /// Conservative — long enough that the user can read the update alert
    /// without the icon flickering away mid-read, short enough that a
    /// stranded `.regular` state self-heals within a minute.
    @MainActor private static let watchdogTimeout: Duration = .seconds(60)

    /// Touched only from main actor (the `runOnMain` helper enforces this).
    /// `@MainActor` makes that explicit to the type checker.
    @MainActor private var revertTask: Task<Void, Never>?

    /// Called when an update is found and Sparkle is about to present it.
    /// Promote to regular app so the window can come to front. `activate`
    /// after the policy flip ensures the window becomes key — without it
    /// the Dock icon appears but focus stays on the previous frontmost app.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        runOnMain { @MainActor in
            Self.promoteActivationPolicy(on: self)
        }
    }

    /// Called before Sparkle shows a modal alert (e.g. "You're up to date",
    /// errors). The alert window inherits activation from the app — without
    /// this, manual checks against the up-to-date branch surface invisibly.
    func standardUserDriverWillShowModalAlert() {
        runOnMain { @MainActor in
            Self.promoteActivationPolicy(on: self)
        }
    }

    /// Revert to menubar-only mode after Sparkle's user-session ends so the
    /// Dock icon doesn't linger. The install-and-relaunch path quits before
    /// this fires; the next launch re-reads `LSUIElement=true` from
    /// Info.plist and starts back as `.accessory` regardless.
    func standardUserDriverWillFinishUpdateSession() {
        runOnMain { @MainActor in
            Self.revertActivationPolicy(on: self)
        }
    }

    // MARK: Private helpers (always main-isolated)

    @MainActor
    private static func promoteActivationPolicy(on delegate: SparkleUserDriverDelegate) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        delegate.revertTask?.cancel()
        delegate.revertTask = Task { @MainActor in
            do {
                try await Task.sleep(for: watchdogTimeout)
            } catch {
                return // cancelled — the legitimate willFinish path ran
            }
            guard !Task.isCancelled else { return }
            Log.app
                .warning(
                    "Sparkle session never called willFinishUpdateSession — forcing .accessory after watchdog"
                )
            NSApp.setActivationPolicy(.accessory)
            delegate.revertTask = nil
        }
    }

    @MainActor
    private static func revertActivationPolicy(on delegate: SparkleUserDriverDelegate) {
        delegate.revertTask?.cancel()
        delegate.revertTask = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Routes the work onto the main actor. Sparkle is expected to call us on
    /// main; if it ever doesn't, log and dispatch — never crash via
    /// `assumeIsolated`'s precondition.
    private func runOnMain(_ body: @MainActor @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Log.app.error("SparkleUserDriverDelegate fired off main thread; dispatching to main")
            DispatchQueue.main.async {
                MainActor.assumeIsolated(body)
            }
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

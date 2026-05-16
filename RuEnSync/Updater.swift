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

    init() {
        // `startingUpdater: true` kicks off the scheduled-check timer
        // immediately. Combined with `SUEnableAutomaticChecks=true` in
        // Info.plist, users get a quiet check at launch and then every
        // `SUScheduledCheckInterval` seconds (24h by default).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
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
        controller.checkForUpdates(nil)
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

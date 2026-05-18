@testable import RuEnSync
import Testing

/// Wake-from-sleep state machine. Mirrors `AppModelYieldTests` shape — the
/// real watchers (NSWorkspace, IOKit) can't fire under XCTest harness, but
/// the handler they invoke is a pure main-actor state transition we can
/// poke directly. Production wiring is in `AppModel.start()`.
@MainActor
struct AppModelWakeTests {
    private func makeModel() -> AppModel {
        AppModel(
            config: Config(
                devices: [],
                layouts: ["ABC", "Russian"],
                appLayoutRules: nil,
                appLayoutSwitchingEnabled: nil,
                debug: nil
            ),
            allowAutoDiscoverySeed: false
        )
    }

    @Test("wake when not yielded records .systemDidWake then triggers reconnect")
    func wakeNotYieldedReconnects() {
        let model = makeModel()

        model.handleDidWake()

        // reconnectAll runs synchronously and emits .reconnectTriggered, so
        // the activity head is reconnect (newest), .systemDidWake below it.
        if case .reconnectTriggered = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("expected .reconnectTriggered at index 0")
        }
        if case .systemDidWake = model.activity.entries[1].kind {
            // ok
        } else {
            Issue.record("expected .systemDidWake at index 1")
        }
    }

    @Test("wake while yielded records .systemDidWake but doesn't rebuild")
    func wakeWhileYieldedSkipsRebuild() {
        let model = makeModel()
        model.handleConflictAppeared(appName: "Vial")
        let linksBefore = model.hidLinks.count

        // No `onConflictCleared` wiring here (start() not called), so
        // ConflictWatcher.refresh() finds no Vial in NSWorkspace but its
        // callback is nil — yieldedTo stays as-is.
        model.handleDidWake()

        #expect(model.yieldedTo == "Vial")
        #expect(model.hidLinks.count == linksBefore)
        if case .systemDidWake = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("expected .systemDidWake at index 0")
        }
    }

    @Test("wake while yielded resumes when conflict watcher rescan clears it")
    func wakeRefreshesConflictAndResumes() {
        let model = makeModel()
        // Mimic the wiring AppModel.start() normally does — without it the
        // refresh-on-wake path is invisible to the test rig.
        model.conflictWatcher.onConflictCleared = { [weak model] in
            model?.handleConflictCleared()
        }
        // Seed the watcher with a Vial that's "currently running" from the
        // watcher's POV. The production seed path scans NSWorkspace; here
        // we plant the bundle ID directly so refresh() observes the
        // running→gone transition.
        model.conflictWatcher.activeBundleIds = ["today.vial"]
        model.handleConflictAppeared(appName: "Vial")
        #expect(model.yieldedTo == "Vial")

        // ConflictWatcher.refresh() scans NSWorkspace; no real Vial process,
        // so onConflictCleared fires synchronously and clears yieldedTo.
        // handleDidWake then returns without a second reconnectAll because
        // the conflict-cleared path already rebuilt links.
        model.handleDidWake()

        #expect(model.yieldedTo == nil)
        // Newest first: .resumedAfterApp from handleConflictCleared,
        // .systemDidWake from handleDidWake, .yieldedToApp from the seed.
        if case .resumedAfterApp = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("expected .resumedAfterApp at index 0")
        }
        if case .systemDidWake = model.activity.entries[1].kind {
            // ok
        } else {
            Issue.record("expected .systemDidWake at index 1")
        }
    }
}

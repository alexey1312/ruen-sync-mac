@testable import RuEnSync
import Testing

/// Yield/resume state machine. The watchers themselves can't be tested in
/// isolation (NSWorkspace + real bundle launches), but the AppModel handlers
/// they trigger are pure state mutations on a main-actor object — easy to
/// poke directly. These tests exercise the documented invariants from
/// `AppModel+Coordination.handleConflictAppeared` / `handleConflictCleared`.
@MainActor
struct AppModelYieldTests {
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

    @Test("first conflict sets yieldedTo and records yieldedToApp")
    func firstConflictRecordsYieldAndUpdatesState() {
        let model = makeModel()
        // Note: activity uses the production SQLite mirror, which carries
        // entries across test runs and caps at capacity. We assert on the
        // newest-first entry's kind rather than on raw counts.

        model.handleConflictAppeared(appName: "Vial")

        #expect(model.yieldedTo == "Vial")
        if case let .yieldedToApp(name) = model.activity.entries[0].kind {
            #expect(name == "Vial")
        } else {
            Issue.record("expected .yieldedToApp at index 0")
        }
        // While yielded, hidLinks and deviceStatuses are both cleared so
        // nothing accidentally races the conflicting app for the device.
        #expect(model.hidLinks.isEmpty)
        #expect(model.deviceStatuses.isEmpty)
    }

    @Test("second conflict while yielded appends activity but keeps yieldedTo")
    func secondConflictAppendsActivityOnly() {
        let model = makeModel()
        model.handleConflictAppeared(appName: "Vial")
        let yieldedAfterFirst = model.yieldedTo

        model.handleConflictAppeared(appName: "QMK Toolbox")

        // yieldedTo remembers the first app — the UI shows one label,
        // even though the activity log carries the full sequence.
        #expect(model.yieldedTo == yieldedAfterFirst)
        // Newest entry is the second yield (QMK Toolbox).
        if case let .yieldedToApp(name) = model.activity.entries[0].kind {
            #expect(name == "QMK Toolbox")
        } else {
            Issue.record("expected .yieldedToApp(QMK Toolbox)")
        }
    }

    @Test("resume when not yielded is a silent no-op")
    func resumeWhenNotYieldedIsNoop() {
        let model = makeModel()
        let newestBefore = model.activity.entries.first?.id

        model.handleConflictCleared()

        #expect(model.yieldedTo == nil)
        // No new entry must have been recorded — the head of the log is
        // still whatever was there before the resume call.
        #expect(model.activity.entries.first?.id == newestBefore)
    }

    @Test("clearing the conflict resumes and records the app name")
    func clearingResumes() {
        let model = makeModel()
        model.handleConflictAppeared(appName: "Vial")

        model.handleConflictCleared()

        #expect(model.yieldedTo == nil)
        // First entry after the resume: .resumedAfterApp("Vial"). The
        // yield entry is still in the log, just one position deeper.
        if case let .resumedAfterApp(name) = model.activity.entries[0].kind {
            #expect(name == "Vial")
        } else {
            Issue.record("expected .resumedAfterApp at index 0")
        }
    }

    @Test("forceResume short-circuits the conflict still-running guard")
    func forceResumeClearsYield() {
        let model = makeModel()
        model.handleConflictAppeared(appName: "Vial")

        model.forceResume()

        #expect(model.yieldedTo == nil)
        if case .resumedAfterApp = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("forceResume should record .resumedAfterApp")
        }
    }

    @Test("reconnect while yielded records the trigger but doesn't rebuild")
    func reconnectWhileYieldedSkipsRebuild() {
        let model = makeModel()
        model.handleConflictAppeared(appName: "Vial")
        let linksBefore = model.hidLinks.count // 0 — cleared at yield

        model.reconnectAll()

        #expect(model.hidLinks.count == linksBefore)
        // The most recent activity entry is the reconnect trigger; the
        // log never sees a "phantom" reconnect-while-yielded link rebuild.
        if case .reconnectTriggered = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("reconnectAll should record .reconnectTriggered first")
        }
    }
}

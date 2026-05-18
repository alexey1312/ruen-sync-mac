import AppKit
@testable import RuEnSync
import Testing

/// `NSWorkspace.shared.notificationCenter` is process-global, but we can post
/// to it from test code and observe our own watcher reacting. The `queue: .main`
/// dispatch hops through the run loop, so we yield once before asserting.
@MainActor
struct SleepWatcherTests {
    @Test("start subscribes and onDidWake fires on didWakeNotification")
    func startDispatches() async {
        let watcher = SleepWatcher()
        var fired = 0
        watcher.onDidWake = { fired += 1 }
        watcher.start()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // Let the main-queue observer run.
        await Task.yield()
        await Task.yield()

        #expect(fired == 1)
        watcher.stop()
    }

    @Test("stop unregisters so subsequent posts no-op")
    func stopUnsubscribes() async {
        let watcher = SleepWatcher()
        var fired = 0
        watcher.onDidWake = { fired += 1 }
        watcher.start()
        watcher.stop()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await Task.yield()
        await Task.yield()

        #expect(fired == 0)
    }

    @Test("double start is idempotent — only one observer registered")
    func doubleStartIsIdempotent() async {
        let watcher = SleepWatcher()
        var fired = 0
        watcher.onDidWake = { fired += 1 }
        watcher.start()
        watcher.start() // hasStarted guard

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await Task.yield()
        await Task.yield()

        #expect(fired == 1)
        watcher.stop()
    }
}

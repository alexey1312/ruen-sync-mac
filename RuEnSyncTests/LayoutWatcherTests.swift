import CoreFoundation
@testable import RuEnSync
import Testing

@MainActor
struct LayoutWatcherTests {
    @Test("selectInputSource returns .listFailed when TISCreateInputSourceList returns nil")
    func selectInputSourceListFailed() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        watcher.inputSourceListProvider = { _, _ in nil }

        // Result<Void, _> isn't Equatable (Void isn't), so match the failure
        // and compare the Equatable error rather than the whole Result.
        guard case let .failure(error) = watcher.selectInputSource(layoutName: "Russian") else {
            Issue.record("expected .failure(.listFailed)")
            return
        }
        #expect(error == .listFailed)
    }

    @Test("selectInputSource returns .notEnabled when TISCreateInputSourceList returns an empty list")
    func selectInputSourceEmptyListNotEnabled() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        let emptyArray = [] as CFArray
        watcher.inputSourceListProvider = { _, _ in Unmanaged.passRetained(emptyArray) }

        guard case let .failure(error) = watcher.selectInputSource(layoutName: "Russian") else {
            Issue.record("expected .failure(.notEnabled)")
            return
        }
        #expect(error == .notEnabled)
    }

    @Test("reconciliation poll picks up a layout change that arrived without a notification")
    func pollCatchesMissedNotification() async throws {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        var currentID = "com.apple.keylayout.ABC"
        watcher.currentSourceIDProvider = { currentID }
        watcher.pollInterval = .milliseconds(20)

        var received: [UInt8] = []
        watcher.onLayoutChanged = { received.append($0) }

        watcher.start()
        #expect(received == [0])

        // Idle poll ticks must not re-dispatch the unchanged layout — the
        // existing dedup is what makes background polling safe for the
        // single-buffered QMK Raw HID endpoint.
        try await Task.sleep(for: .milliseconds(100))
        #expect(received == [0])

        // Simulate the desync scenario: macOS switched but the DNC
        // notification was dropped (or raced a stale TIS read). Only the
        // poll can catch this.
        currentID = "com.apple.keylayout.Russian"
        try await Task.sleep(for: .milliseconds(300))
        #expect(received == [0, 1])
        #expect(watcher.lastIndex == 1)

        watcher.stop()
    }
}

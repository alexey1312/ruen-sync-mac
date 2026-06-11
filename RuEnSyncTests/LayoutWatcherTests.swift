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
}

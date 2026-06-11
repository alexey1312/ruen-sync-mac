import CoreFoundation
@testable import RuEnSync
import Testing

@MainActor
struct LayoutWatcherTests {
    @Test("selectInputSource returns .listFailed when TISCreateInputSourceList returns nil")
    func selectInputSourceListFailed() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        watcher.inputSourceListProvider = { _, _ in nil }

        let result = watcher.selectInputSource(layoutName: "Russian")
        #expect(result == .failure(.listFailed))
    }

    @Test("selectInputSource returns .notEnabled when TISCreateInputSourceList returns an empty list")
    func selectInputSourceEmptyListNotEnabled() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        let emptyArray = [] as CFArray
        watcher.inputSourceListProvider = { _, _ in Unmanaged.passRetained(emptyArray) }

        let result = watcher.selectInputSource(layoutName: "Russian")
        #expect(result == .failure(.notEnabled))
    }
}

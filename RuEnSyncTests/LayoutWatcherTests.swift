import CoreFoundation
@testable import RuEnSync
import Testing

@MainActor
struct LayoutWatcherTests {
    @Test("selectInputSource returns .listFailed when TISCreateInputSourceList returns nil")
    func selectInputSourceListFailed() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        watcher._createInputSourceListOverride = { _, _ in nil }

        let result = watcher.selectInputSource(layoutName: "Russian")
        #expect(result == .failure(.listFailed))
    }

    @Test("selectInputSource returns .notEnabled when TISCreateInputSourceList returns empty array")
    func selectInputSourceEmptyListNotEnabled() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        let emptyArray = [] as CFArray
        watcher._createInputSourceListOverride = { _, _ in
            Unmanaged.passRetained(emptyArray)
        }

        let result = watcher.selectInputSource(layoutName: "Russian")
        #expect(result == .failure(.notEnabled))
    }
}

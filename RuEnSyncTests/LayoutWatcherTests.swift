import Foundation
@testable import RuEnSync
import Testing

@MainActor
struct LayoutWatcherTests {
    @Test("selectInputSource with non-existent layout returns notEnabled or listFailed")
    func selectInputSourceNotEnabled() {
        let watcher = LayoutWatcher(layouts: ["ABC", "Russian"])
        let result = watcher.selectInputSource(layoutName: "NonExistentLayout")

        // On a real macOS machine where the requested layout doesn't exist, this returns .notEnabled.
        // On a test environment or if TISCreateInputSourceList fails entirely, it may return .listFailed.
        switch result {
        case .failure(.notEnabled), .failure(.listFailed):
            #expect(true) // Success
        default:
            Issue.record("Expected .notEnabled or .listFailed, got \(result)")
        }
    }
}

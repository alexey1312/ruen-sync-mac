import Foundation
@testable import RuEnSync
import Testing

@MainActor
struct ActivityDatabaseTests {
    @Test("init throws when given an invalid path (e.g. a directory)")
    func initThrowsOnInvalidPath() {
        #expect(throws: (any Error).self) {
            _ = try ActivityDatabase(path: "/")
        }
    }
}

@testable import RuEnSync
import Foundation
import Testing

@MainActor
struct ActivityDatabaseTests {
    @Test("init with invalid path throws error")
    func initFailsWithInvalidPath() throws {
        // Attempt to create a database at a path that doesn't exist/can't be written to
        let invalidPath = "/this/path/does/not/exist/db.sqlite"

        #expect(throws: Error.self) {
            _ = try ActivityDatabase(path: invalidPath)
        }
    }
}

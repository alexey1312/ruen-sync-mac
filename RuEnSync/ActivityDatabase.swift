import Foundation
import SQLite

// MARK: - ActivityDatabase

/// SQLite-backed storage for the activity log. Owned by `ActivityStore`,
/// not used directly elsewhere.
///
/// Schema is a single `activity` table indexed by timestamp. The
/// `ActivityKind` enum is flattened into a discriminator string + three
/// nullable payload columns (`device_name`, `reason`, `label`); each case
/// uses the subset of columns it cares about. This is simpler to query
/// than JSON-blob encoding and lets the indexes do their job.
///
/// WAL journal mode is enabled pre-emptively even though we currently
/// have a single writer — it makes any future CLI/MCP companion safe to
/// co-write without locking out the menubar process.
final class ActivityDatabase: @unchecked Sendable {
    private let connection: Connection

    /// Opens the database at `path`. Pass `":memory:"` for an in-memory
    /// instance used by tests.
    init(path: String) throws {
        connection = try Connection(path)
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA busy_timeout=3000")
        try createSchemaIfNeeded()
    }

    // MARK: - Schema

    private static let activity = Table("activity")
    private static let colID = SQLite.Expression<String>("id")
    private static let colTimestamp = SQLite.Expression<Double>("timestamp")
    private static let colKind = SQLite.Expression<String>("kind")
    private static let colDeviceName = SQLite.Expression<String?>("device_name")
    private static let colReason = SQLite.Expression<String?>("reason")
    private static let colLabel = SQLite.Expression<String?>("label")

    private func createSchemaIfNeeded() throws {
        try connection.run(Self.activity.create(ifNotExists: true) { t in
            t.column(Self.colID, primaryKey: true)
            t.column(Self.colTimestamp)
            t.column(Self.colKind)
            t.column(Self.colDeviceName)
            t.column(Self.colReason)
            t.column(Self.colLabel)
        })
        try connection.run(Self.activity.createIndex(Self.colTimestamp, ifNotExists: true))
    }

    // MARK: - CRUD

    func insert(_ entry: ActivityEntry) throws {
        let storable = entry.kind.storable
        try connection.run(Self.activity.insert(
            or: .replace,
            Self.colID <- entry.id.uuidString,
            Self.colTimestamp <- entry.timestamp.timeIntervalSince1970,
            Self.colKind <- storable.discriminator,
            Self.colDeviceName <- storable.deviceName,
            Self.colReason <- storable.reason,
            Self.colLabel <- storable.label
        ))
    }

    /// Returns the `limit` most recent entries, newest first.
    func loadRecent(limit: Int) -> [ActivityEntry] {
        let query = Self.activity
            .order(Self.colTimestamp.desc)
            .limit(limit)
        do {
            return try connection.prepare(query).compactMap(rowToEntry)
        } catch {
            Log.app.error("ActivityDatabase loadRecent failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func clear() throws {
        try connection.run(Self.activity.delete())
    }

    /// Total row count. Cheap (`COUNT(*)` on a small indexed table).
    func count() -> Int {
        (try? connection.scalar(Self.activity.count)) ?? 0
    }

    // MARK: - Helpers

    private func rowToEntry(_ row: Row) -> ActivityEntry? {
        guard let id = UUID(uuidString: row[Self.colID]) else { return nil }
        let kind = ActivityKind(
            discriminator: row[Self.colKind],
            deviceName: row[Self.colDeviceName],
            reason: row[Self.colReason],
            label: row[Self.colLabel]
        )
        guard let kind else { return nil }
        return ActivityEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: row[Self.colTimestamp]),
            kind: kind
        )
    }
}

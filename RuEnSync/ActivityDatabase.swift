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
///
/// `@MainActor`-isolated because the only caller is `ActivityStore`, which
/// itself runs on the main actor. Pinning isolation here lets Swift 6
/// enforce single-threaded access at the type system level (and avoids the
/// `@unchecked Sendable` escape hatch).
@MainActor
final class ActivityDatabase {
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

    // Static `Expression`s on a `@MainActor` class would otherwise inherit
    // main-actor isolation — making them unusable from any future
    // nonisolated test helper or query builder. Pinning them `nonisolated`
    // matches the project-wide rule (see CLAUDE.md, architectural note #1).
    private nonisolated static let activity = Table("activity")
    private nonisolated static let colID = SQLite.Expression<String>("id")
    private nonisolated static let colTimestamp = SQLite.Expression<Double>("timestamp")
    private nonisolated static let colKind = SQLite.Expression<String>("kind")
    private nonisolated static let colDeviceName = SQLite.Expression<String?>("device_name")
    private nonisolated static let colReason = SQLite.Expression<String?>("reason")
    private nonisolated static let colLabel = SQLite.Expression<String?>("label")

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
        let discriminator = row[Self.colKind]
        let kind = ActivityKind(
            discriminator: discriminator,
            deviceName: row[Self.colDeviceName],
            reason: row[Self.colReason],
            label: row[Self.colLabel]
        )
        guard let kind else {
            // Most likely cause: a row written by a future build whose
            // discriminator this build doesn't know yet. Surface at
            // `.warning` so it shows up in diagnostics exports without
            // panicking the user.
            Log.app
                .warning(
                    "ActivityDatabase: dropping row with unknown/incomplete kind '\(discriminator, privacy: .public)'"
                )
            return nil
        }
        return ActivityEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: row[Self.colTimestamp]),
            kind: kind
        )
    }
}

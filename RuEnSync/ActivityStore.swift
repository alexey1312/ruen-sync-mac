import Foundation
import Observation

// MARK: - ActivityKind

/// Categorical tag for an activity entry. Kept narrow on purpose — every new
/// case adds a row type the menubar must render, so resist the temptation to
/// add "miscellaneous". Each case carries just enough to format a row.
enum ActivityKind: Equatable {
    case layoutChanged(label: String)
    case deviceConnected(name: String)
    case deviceDisconnected(name: String, reason: String)
    case deviceOfflineReasonChanged(name: String, reason: String)
    case osHandshakeSent(name: String)
    case osHandshakeFailed(name: String)
    case reconnectTriggered
    case yieldedToApp(name: String)
    case resumedAfterApp(name: String)
    case appLayoutOverride(bundleId: String, layoutName: String)
    case appLayoutOverrideFailed(bundleId: String, layoutName: String, reason: String)
    case configReloaded
    case configInvalid

    /// SF Symbol name for the row icon. Picked so the icon alone gives the
    /// user a rough idea of severity (`xmark.*` = bad, `arrow.triangle.*` =
    /// transition, `keyboard.*` = device).
    var symbol: String {
        switch self {
        case .layoutChanged: "arrow.triangle.2.circlepath"
        case .deviceConnected: "keyboard.fill"
        case .deviceDisconnected: "keyboard.badge.ellipsis"
        case .deviceOfflineReasonChanged: "exclamationmark.triangle.fill"
        case .osHandshakeSent: "checkmark.seal.fill"
        case .osHandshakeFailed: "xmark.seal.fill"
        case .reconnectTriggered: "arrow.clockwise"
        case .yieldedToApp: "pause.circle.fill"
        case .resumedAfterApp: "play.circle.fill"
        case .appLayoutOverride: "app.badge.fill"
        case .appLayoutOverrideFailed: "exclamationmark.app.fill"
        case .configReloaded: "doc.badge.gearshape"
        case .configInvalid: "doc.badge.ellipsis"
        }
    }

    /// Short headline shown in the activity row. Single sentence, no period.
    /// Localized via the String catalog. Interpolated values keep their
    /// position with explicit `%1$@` / `%2$@` placeholders in Russian to
    /// preserve word order (Russian places the subject before "connected"
    /// but after "Resumed after", etc. — see the catalog).
    var headline: String {
        switch self {
        case let .layoutChanged(label):
            String(localized: "Layout → \(label)")
        case let .deviceConnected(name):
            String(localized: "\(name) connected")
        case let .deviceDisconnected(name, reason):
            String(localized: "\(name) disconnected — \(reason.lowercasedFirstLetter())")
        case let .deviceOfflineReasonChanged(name, reason):
            String(localized: "\(name) — \(reason.lowercasedFirstLetter())")
        case let .osHandshakeSent(name):
            String(localized: "MAC handshake → \(name)")
        case let .osHandshakeFailed(name):
            String(localized: "MAC handshake failed → \(name)")
        case .reconnectTriggered:
            String(localized: "Reconnect triggered")
        case let .yieldedToApp(name):
            String(localized: "Yielded to \(name)")
        case let .resumedAfterApp(name):
            String(localized: "Resumed after \(name)")
        case let .appLayoutOverride(bundleId, layoutName):
            String(localized: "\(bundleId) → \(layoutName)")
        case let .appLayoutOverrideFailed(bundleId, layoutName, reason):
            String(localized: "\(bundleId) → \(layoutName) — \(reason)")
        case .configReloaded:
            String(localized: "Config reloaded")
        case .configInvalid:
            String(localized: "Config invalid — keeping previous")
        }
    }
}

// MARK: - ActivityKind ↔ storage

/// Flat representation used by `ActivityDatabase`. We deliberately don't
/// reach for `Codable` here — the columnar layout keeps SQL queries
/// (filter by `kind`, aggregate by `device_name`) trivial and indexable.
struct ActivityKindStorable {
    let discriminator: String
    let deviceName: String?
    let reason: String?
    let label: String?
}

extension ActivityKind {
    var storable: ActivityKindStorable {
        switch self {
        case let .layoutChanged(label):
            .init(discriminator: "layoutChanged", deviceName: nil, reason: nil, label: label)
        case let .deviceConnected(name):
            .init(discriminator: "deviceConnected", deviceName: name, reason: nil, label: nil)
        case let .deviceDisconnected(name, reason):
            .init(discriminator: "deviceDisconnected", deviceName: name, reason: reason, label: nil)
        case let .deviceOfflineReasonChanged(name, reason):
            .init(discriminator: "deviceOfflineReasonChanged", deviceName: name, reason: reason, label: nil)
        case let .osHandshakeSent(name):
            .init(discriminator: "osHandshakeSent", deviceName: name, reason: nil, label: nil)
        case let .osHandshakeFailed(name):
            .init(discriminator: "osHandshakeFailed", deviceName: name, reason: nil, label: nil)
        case .reconnectTriggered:
            .init(discriminator: "reconnectTriggered", deviceName: nil, reason: nil, label: nil)
        case let .yieldedToApp(name):
            .init(discriminator: "yieldedToApp", deviceName: name, reason: nil, label: nil)
        case let .resumedAfterApp(name):
            .init(discriminator: "resumedAfterApp", deviceName: name, reason: nil, label: nil)
        case let .appLayoutOverride(bundleId, layoutName):
            // We reuse `deviceName` for the bundle ID and `label` for the
            // target layout — both are sendable strings, and adding a new
            // column would require an ALTER TABLE. Round-trip is exact.
            .init(discriminator: "appLayoutOverride", deviceName: bundleId, reason: nil, label: layoutName)
        case let .appLayoutOverrideFailed(bundleId, layoutName, reason):
            // Same column reuse as `.appLayoutOverride`, with the existing
            // `reason` slot carrying the failure mode — no schema change.
            .init(discriminator: "appLayoutOverrideFailed", deviceName: bundleId, reason: reason, label: layoutName)
        case .configReloaded:
            .init(discriminator: "configReloaded", deviceName: nil, reason: nil, label: nil)
        case .configInvalid:
            .init(discriminator: "configInvalid", deviceName: nil, reason: nil, label: nil)
        }
    }

    // swiftlint:disable cyclomatic_complexity

    /// Reverse of `storable`. Returns `nil` for unknown discriminators (e.g.
    /// when a newer build wrote a row this build doesn't understand yet) or
    /// for rows missing required payload — defensively dropping a corrupted
    /// row is better than crashing the menubar.
    init?(discriminator: String, deviceName: String?, reason: String?, label: String?) {
        switch discriminator {
        case "layoutChanged":
            guard let label else { return nil }
            self = .layoutChanged(label: label)
        case "deviceConnected":
            guard let deviceName else { return nil }
            self = .deviceConnected(name: deviceName)
        case "deviceDisconnected":
            guard let deviceName, let reason else { return nil }
            self = .deviceDisconnected(name: deviceName, reason: reason)
        case "deviceOfflineReasonChanged":
            guard let deviceName, let reason else { return nil }
            self = .deviceOfflineReasonChanged(name: deviceName, reason: reason)
        case "osHandshakeSent":
            guard let deviceName else { return nil }
            self = .osHandshakeSent(name: deviceName)
        case "osHandshakeFailed":
            guard let deviceName else { return nil }
            self = .osHandshakeFailed(name: deviceName)
        case "reconnectTriggered":
            self = .reconnectTriggered
        case "yieldedToApp":
            guard let deviceName else { return nil }
            self = .yieldedToApp(name: deviceName)
        case "resumedAfterApp":
            guard let deviceName else { return nil }
            self = .resumedAfterApp(name: deviceName)
        case "appLayoutOverride":
            guard let deviceName, let label else { return nil }
            self = .appLayoutOverride(bundleId: deviceName, layoutName: label)
        case "appLayoutOverrideFailed":
            guard let deviceName, let label, let reason else { return nil }
            self = .appLayoutOverrideFailed(bundleId: deviceName, layoutName: label, reason: reason)
        case "configReloaded":
            self = .configReloaded
        case "configInvalid":
            self = .configInvalid
        default:
            return nil
        }
    }
}

// MARK: - ActivityEntry

/// One row in the activity log. Immutable. Comparable for tests.
struct ActivityEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: ActivityKind

    init(id: UUID = UUID(), timestamp: Date = Date(), kind: ActivityKind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }
}

// MARK: - ActivityStore

/// Persistence-backed, newest-first activity log. The in-memory `entries`
/// array mirrors the most recent `capacity` rows from SQLite (`activity`
/// table at `~/.config/RuEnSync/activity.db`). Writes go to both the DB
/// and the mirror; the mirror is what the menubar UI binds to via
/// `@Observable`.
///
/// Persistence lets users see activity from prior sessions and gives any
/// future CLI / health-check companion a single source of truth, while the
/// bounded mirror keeps the menubar's SwiftUI rebuilds cheap.
@MainActor
@Observable
final class ActivityStore {
    /// Newest first. Mirrors the latest `capacity` rows from the DB.
    private(set) var entries: [ActivityEntry] = []

    let capacity: Int
    private let database: ActivityDatabase?

    /// Production initialiser — opens (or creates) the SQLite store next to
    /// the config file. A failure here downgrades the store to in-memory
    /// only; the app still works, the user just loses cross-launch history.
    init(capacity: Int = 100) {
        self.capacity = capacity
        let path = Self.defaultDatabaseURL().path
        do {
            let db = try ActivityDatabase(path: path)
            database = db
            entries = db.loadRecent(limit: capacity)
        } catch {
            Log.app.error(
                "ActivityStore failed to open \(path, privacy: .public) — running in-memory: \(error.localizedDescription, privacy: .public)"
            )
            database = nil
        }
    }

    /// Test-only initialiser. Pass in a pre-built database (in-memory or
    /// pointed at a temp file) so tests don't touch the user's real log.
    init(capacity: Int = 100, database: ActivityDatabase?) {
        self.capacity = capacity
        self.database = database
        entries = database?.loadRecent(limit: capacity) ?? []
    }

    /// Append a new entry. Persists to SQLite first, then prepends to the
    /// in-memory mirror. The capacity cap applies to the mirror only — the
    /// DB keeps the full history.
    func record(_ kind: ActivityKind) {
        let entry = ActivityEntry(kind: kind)
        if let database {
            do {
                try database.insert(entry)
            } catch {
                Log.app.error("ActivityStore insert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// Clear all entries — from the DB and the mirror. Wired to the
    /// "Clear activity" menu item.
    func clear() {
        if let database {
            do {
                try database.clear()
            } catch {
                Log.app.error("ActivityStore clear failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        entries.removeAll()
    }

    /// Default storage location: same directory as `config.json`. Created
    /// on demand by `ActivityDatabase` itself (`Connection` will open the
    /// file inside an existing dir; the dir is created by `ConfigStore`).
    private static func defaultDatabaseURL() -> URL {
        ConfigStore.configURL.deletingLastPathComponent()
            .appendingPathComponent("activity.db")
    }
}

// MARK: - Formatting helpers

extension ActivityEntry {
    /// "5s ago" / "2 min ago" / "1 wk ago". Allocated per call on purpose —
    /// `RelativeDateTimeFormatter` is not `Sendable`, and the formatter is
    /// cheap (≤ 50 µs on M1) relative to a single SwiftUI row render.
    func relativeTimestamp(reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: reference)
    }
}

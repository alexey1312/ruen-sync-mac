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
        }
    }

    /// Short headline shown in the activity row. Single sentence, no period.
    var headline: String {
        switch self {
        case let .layoutChanged(label): "Layout → \(label)"
        case let .deviceConnected(name): "\(name) connected"
        case let .deviceDisconnected(name, reason): "\(name) disconnected — \(reason.lowercasedFirstLetter())"
        case let .deviceOfflineReasonChanged(name, reason): "\(name) — \(reason.lowercasedFirstLetter())"
        case let .osHandshakeSent(name): "MAC handshake → \(name)"
        case let .osHandshakeFailed(name): "MAC handshake failed → \(name)"
        case .reconnectTriggered: "Reconnect triggered"
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

/// Fixed-capacity, newest-first ring buffer for recent app events. Lives in
/// memory only — the app is a single-process daemon and persisting across
/// launches would mostly capture "the last time you rebooted", which has no
/// diagnostic value. SQLite/JSON persistence is intentionally not used.
@MainActor
@Observable
final class ActivityStore {
    /// Newest first. Capped at `capacity`; older entries fall off the back.
    private(set) var entries: [ActivityEntry] = []

    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Append a new entry. O(1) amortised; trims from the tail when over
    /// `capacity` so we never grow unbounded inside a long-running session.
    func record(_ kind: ActivityKind) {
        entries.insert(ActivityEntry(kind: kind), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// Clear all entries. Wired to the "Clear activity" menu item.
    func clear() {
        entries.removeAll()
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

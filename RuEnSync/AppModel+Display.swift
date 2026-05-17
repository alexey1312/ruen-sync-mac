import Foundation

// MARK: - Display helpers

extension AppModel {
    /// Short language label (`EN`, `RU`, or `—` when status is unknown).
    var languageLabel: String {
        switch layoutIndex {
        case .some(0): "EN"
        case .some: "RU"
        case .none: "—"
        }
    }

    /// True iff any configured device is currently connected. Derived from
    /// `deviceStatuses`; no shadow field to keep in sync.
    var isAnyDeviceConnected: Bool {
        deviceStatuses.contains { if case .connected = $0.state { true } else { false } }
    }

    /// Top-level human-readable status — used when there's a single device or
    /// no devices, otherwise the UI iterates `deviceStatuses` directly.
    var connectionDescription: String {
        Self.describe(deviceStatuses)
    }

    /// Pure, testable formatter for the aggregate status line.
    static func describe(_ statuses: [DeviceStatus]) -> String {
        if statuses.isEmpty {
            return String(localized: "No device configured")
        }
        if statuses.count == 1, let status = statuses.first {
            return status.summary
        }
        let connectedCount = statuses.count(where: {
            if case .connected = $0.state { return true }
            return false
        })
        return String(localized: "\(connectedCount) of \(statuses.count) connected")
    }
}

extension AppModel.DeviceStatus {
    /// e.g. "Corne — connected" / "Corne — device busy (qmk-hid-host running?)".
    /// The "connected" path is plain English even in the localized catalog
    /// because most users see the device name there ("Corne", a proper noun)
    /// and adding a "%@ — подключено" form is consistent with the activity
    /// log's "%@ connected" entry — both reuse the same catalog string.
    var summary: String {
        switch state {
        case .connected:
            // Distinct from the activity log's "%@ connected" — this is the
            // dropdown row, which uses the "%@ — connected" separator for
            // visual consistency with the offline variant below.
            String(localized: "\(name) — connected", comment: "Menubar dropdown row, connected")
        case let .offline(reason):
            String(localized: "\(name) — \(reason.menuLabel.lowercasedFirstLetter())")
        }
    }

    var productIdLabel: String {
        String(format: "0x%04X", productId)
    }
}

// MARK: - String helper

extension String {
    /// Lowercases the first character. Used to splice `OfflineReason.menuLabel`
    /// ("Not connected") into a sentence after "—" without double-capitalising.
    func lowercasedFirstLetter() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

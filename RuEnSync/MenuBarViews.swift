import SwiftUI

// MARK: - CheckForUpdatesMenuItem

/// Menu item that triggers Sparkle's update check. We can't bind directly to
/// `updater.canCheckForUpdates` because Sparkle's `SPUUpdater` is KVO-based,
/// not `@Observable`; the view-model in `Updater.swift` bridges KVO into
/// `@Published`, which SwiftUI's `@StateObject` knows how to track. This is
/// the pattern Sparkle's own SwiftUI docs recommend.
///
/// `@StateObject` rather than `@ObservedObject`: this view owns the lifetime
/// of `CheckForUpdatesViewModel`. With `@ObservedObject`, a parent re-render
/// would rebuild the VM (and its KVO subscription), silently breaking the
/// disable-while-checking behaviour.
struct CheckForUpdatesMenuItem: View {
    let updater: Updater
    @StateObject private var checker: CheckForUpdatesViewModel

    init(updater: Updater) {
        self.updater = updater
        _checker = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater.updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
    }
}

// MARK: - Device row

struct MenubarDeviceRow: View {
    let status: AppModel.DeviceStatus

    var body: some View {
        Label(status.summary, systemImage: symbol)
        Text("Product ID: \(status.productIdLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch status.state {
        case .connected: "keyboard.fill"
        case let .offline(reason):
            switch reason {
            case .exclusiveAccess: "exclamationmark.triangle.fill"
            case .openFailed, .managerOpenFailed: "xmark.octagon"
            case .awaitingDevice: "keyboard.badge.ellipsis"
            }
        }
    }
}

// MARK: - Activity row

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        // One menu item per entry. Native .menu sub-menus don't let us put
        // arbitrary multi-line views inside a row, so we lean on Label's
        // built-in icon + headline layout and put the timestamp on the line.
        Label("\(entry.kind.headline) — \(entry.relativeTimestamp())", systemImage: entry.kind.symbol)
    }
}

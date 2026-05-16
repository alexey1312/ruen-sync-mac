import Foundation
import ServiceManagement

// MARK: - LoginItem

/// Registers the app to launch at login via `SMAppService.mainApp`. Appears
/// in *System Settings → General → Login Items* as a regular toggle the user
/// can disable. No plist plumbing, no `launchctl`.
enum LoginItem {
    /// Registers the app if it isn't already a login item. Idempotent: safe
    /// to call on every launch.
    static func registerIfNeeded() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            Log.app.debug("login item already enabled")
        case .requiresApproval:
            Log.app.info("login item registered, awaiting user approval in System Settings")
        case .notRegistered, .notFound:
            do {
                try service.register()
                Log.app.info("registered as login item")
            } catch {
                Log.app.error("failed to register as login item: \(error.localizedDescription, privacy: .public)")
            }
        @unknown default:
            Log.app.warning("unknown SMAppService status \(String(describing: service.status), privacy: .public)")
        }
    }

    /// Unregister from login items. Not currently wired to UI, but kept here
    /// so we don't go hunting later.
    static func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            Log.app.info("unregistered from login items")
        } catch {
            Log.app.error("failed to unregister: \(error.localizedDescription, privacy: .public)")
        }
    }
}

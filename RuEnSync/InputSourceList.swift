import Carbon.HIToolbox.TextInputSources
import Foundation

// MARK: - InputSourceList

/// Helpers around `TISCreateInputSourceList` for the Settings UI. The
/// Settings → Layouts tab uses this to suggest known macOS input sources
/// to add, and to display friendly names alongside raw suffixes.
enum InputSourceList {
    /// Returns the `.`-suffixes of all currently enabled keyboard input
    /// sources — the same form `LayoutResolver.resolveIndex` expects in
    /// `Config.layouts`. e.g. `["ABC", "Russian", "RussianPhonetic"]`.
    /// Order matches the macOS Input Source list (system-defined).
    static func enabledKeyboardSuffixes() -> [String] {
        sources().compactMap { source in
            guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else { return nil }
            return id.split(separator: ".").last.map(String.init)
        }
    }

    // Wrap NSLock with @unchecked Sendable to suppress Swift 6 warnings since NSLock itself
    // is thread-safe but the swift typechecker doesn't natively mark it Sendable on all SDKs.
    private final class CacheLock: @unchecked Sendable {
        let lock = NSLock()
        var cache: [String: String]?
    }
    private static let displayNamesCache = CacheLock()

    /// Friendly localized label for a layout suffix, e.g. `"Russian"` →
    /// `"Russian"` (or `"Русская"` if macOS is in Russian). Falls back to
    /// the suffix itself when the source isn't currently enabled.
    static func displayName(for suffix: String) -> String {
        displayNamesCache.lock.lock()
        if let existing = displayNamesCache.cache {
            displayNamesCache.lock.unlock()
            return existing[suffix] ?? suffix
        }
        displayNamesCache.lock.unlock()

        var built: [String: String] = [:]
        for source in sources() {
            guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else { continue }
            let candidate = id.split(separator: ".").last.map(String.init) ?? id
            if built[candidate] == nil {
                built[candidate] = stringProperty(source, key: kTISPropertyLocalizedName) ?? candidate
            }
        }

        displayNamesCache.lock.lock()
        if displayNamesCache.cache == nil {
            displayNamesCache.cache = built
        }
        let existing = displayNamesCache.cache!
        displayNamesCache.lock.unlock()
        return existing[suffix] ?? suffix
    }

    // MARK: Internal

    private static func sources() -> [TISInputSource] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
        ]
        guard
            let unmanaged = TISCreateInputSourceList(filter as CFDictionary, false),
            let array = unmanaged.takeRetainedValue() as? [TISInputSource]
        else { return [] }
        return array
    }

    private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

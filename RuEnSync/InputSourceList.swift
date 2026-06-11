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

    /// Friendly localized label for a layout suffix, e.g. `"Russian"` →
    /// `"Russian"` (or `"Русская"` if macOS is in Russian). Falls back to
    /// the suffix itself when the source isn't currently enabled.
    static func displayName(for suffix: String) -> String {
        Cache.shared.displayName(for: suffix) {
            var map: [String: String] = [:]
            for source in sources() {
                guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else { continue }
                let candidate = id.split(separator: ".").last.map(String.init) ?? id
                let localized = stringProperty(source, key: kTISPropertyLocalizedName) ?? candidate
                map[candidate] = localized
            }
            return map
        }
    }

    // MARK: Internal

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private var displayNames: [String: String] = [:]
        private let lock = NSLock()

        func displayName(for suffix: String, resolveAll: () -> [String: String]) -> String {
            lock.lock()
            if let cached = displayNames[suffix] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let all = resolveAll()

            lock.lock()
            for (key, value) in all {
                displayNames[key] = value
            }
            let result = displayNames[suffix] ?? suffix
            displayNames[suffix] = result
            lock.unlock()

            return result
        }
    }

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

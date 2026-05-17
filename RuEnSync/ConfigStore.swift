import Foundation

// MARK: - Configuration schema

/// On-disk config. Schema is compatible with qmk-hid-host's `config.json`
/// so users migrating from the Rust daemon can reuse `~/.config/RuEnSync/`
/// (or just symlink to `~/.config/qmk-hid-host/`).
struct Config: Codable, Equatable {
    struct Device: Codable, Equatable {
        let name: String
        /// Hex string like "0x0001". Matches against `kIOHIDProductIDKey`.
        let productId: String
        /// Optional. Defaults to `0xFF60` (QMK Raw HID convention).
        let usagePage: UInt32?
        /// Optional. Defaults to `0x61` (QMK Raw HID convention).
        let usage: UInt32?
    }

    /// A single per-app layout switching rule. Either `bundleId` (exact match)
    /// or `bundleIdPrefix` is required; if both are set, exact wins. `layout`
    /// is a suffix from `Config.layouts` — e.g. `"ABC"` or `"Russian"`. Apps
    /// whose bundle ID doesn't match any rule keep whatever layout was active.
    struct AppLayoutRule: Codable, Equatable {
        /// Exact bundle identifier (e.g. `"com.apple.dt.Xcode"`).
        var bundleId: String?
        /// Bundle identifier prefix (e.g. `"com.jetbrains."`) — catches all
        /// JetBrains IDEs with one rule. Matched only if `bundleId` is nil.
        var bundleIdPrefix: String?
        /// Layout name as it appears in `Config.layouts` — the suffix after
        /// the last dot of a `kTISPropertyInputSourceID`, e.g. `"Russian"`.
        var layout: String
    }

    var devices: [Device]
    /// Ordered list of `TISPropertyInputSourceID` suffixes (the part after the
    /// last `.`). The index of the active layout in this array is sent as
    /// `data[1]` to the keyboard. Firmware treats `0 → EN`, anything else → RU.
    var layouts: [String]

    /// Optional rules for automatically switching the macOS input source when
    /// a configured app becomes active. Backward-compatible: a config file
    /// without this key behaves identically to the previous schema.
    var appLayoutRules: [AppLayoutRule]?

    /// Master switch for per-app layout switching. When `false` (or
    /// `appLayoutRules` empty), the AppContextWatcher does nothing. Defaults
    /// to `true` so adding rules to an existing config "just works" without
    /// also requiring the user to enable the feature.
    var appLayoutSwitchingEnabled: Bool?

    /// Per-feature debug toggles. Off by default; enabling them costs CPU
    /// and memory (ring-buffer writes, persistent caches), so they're not
    /// suitable for production use.
    struct Debug: Codable, Equatable {
        /// When true, every `HIDLink.send` enqueues a copy of the packet in
        /// the inspector ring-buffer. When false (or unset), the buffer
        /// stays empty and no allocations occur on the hot path.
        var hidInspector: Bool?
    }

    var debug: Debug?

    static let `default` = Config(
        devices: [
            .init(name: "Corne", productId: "0x0001", usagePage: nil, usage: nil),
        ],
        layouts: ["ABC", "Russian"],
        appLayoutRules: nil,
        appLayoutSwitchingEnabled: nil,
        debug: nil
    )
}

// MARK: - Resolved device descriptor

/// Device after `productId` hex string is parsed. Plus default usage/usagePage.
struct ResolvedDevice: Equatable {
    let name: String
    let productId: UInt32
    let usagePage: UInt32
    let usage: UInt32

    static let qmkUsagePage: UInt32 = 0xFF60
    static let qmkUsage: UInt32 = 0x61

    init?(_ device: Config.Device) {
        guard let pid = ResolvedDevice.parseHex(device.productId) else { return nil }
        name = device.name
        productId = pid
        usagePage = device.usagePage ?? Self.qmkUsagePage
        usage = device.usage ?? Self.qmkUsage
    }

    /// Parses "0x0001" / "0X1" / "1" → UInt32. Returns nil on invalid input.
    static func parseHex(_ string: String) -> UInt32? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        return UInt32(trimmed, radix: 10) ?? UInt32(trimmed, radix: 16)
    }
}

// MARK: - Store

enum ConfigStore {
    /// `~/.config/RuEnSync/config.json` — same layout as qmk-hid-host's path.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/RuEnSync/config.json")
    }

    /// Loads config from disk. If the file is missing, writes the default and
    /// returns that. If the file is malformed, logs a warning and falls back
    /// to the default (does **not** overwrite the bad file — preserves user
    /// intent so they can debug).
    static func loadOrSeedDefaults() -> Config {
        let url = configURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            do {
                try writeDefault(to: url)
                Log.config.info("seeded default config at \(url.path, privacy: .public)")
            } catch {
                let message = error.localizedDescription
                Log.config
                    .error(
                        "failed to seed default config at \(url.path, privacy: .public): \(message, privacy: .public)"
                    )
            }
            return .default
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            Log.config.info("loaded config from \(url.path, privacy: .public)")
            return decoded
        } catch {
            let message = error.localizedDescription
            Log.config
                .error(
                    "failed to parse config at \(url.path, privacy: .public): \(message, privacy: .public) — using defaults"
                )
            return .default
        }
    }

    /// Writes the default config JSON to `url`, creating parent dirs as needed.
    static func writeDefault(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Config.default)
        try data.write(to: url, options: .atomic)
    }

    /// True for a brief window while our own write is in-flight. The
    /// directory file-watcher reads this flag and skips one fire so the
    /// app doesn't reload its own write (which would still be correct,
    /// just a wasted activity-log entry + log line).
    @MainActor private(set) static var selfWritingMarker: Date?

    /// Persists `config` atomically (temp-file + rename, same as
    /// `writeDefault`). Sets a brief self-write marker so the file watcher
    /// can ignore the resulting fsevent — see `watch(onChange:)`.
    @MainActor
    static func save(_ config: Config) throws {
        let url = configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        selfWritingMarker = Date()
        try data.write(to: url, options: .atomic)
        Log.config.info("config saved to \(url.path, privacy: .public)")
    }

    /// Watches `~/.config/RuEnSync/` for changes and reloads the config on
    /// each modification. Returns the source so the caller can keep it alive
    /// and cancel on teardown. We watch the **parent directory**, not the
    /// file itself, because most editors save through atomic
    /// write-temp-then-rename, which gives the original file a new inode and
    /// invalidates any FD held on it. Watching the dir survives that pattern.
    ///
    /// The handler is dispatched on the main queue and re-enters @MainActor
    /// before calling `onChange`. A burst of fsevents collapses naturally
    /// because we always read the latest file on every fire.
    static func watch(onChange: @MainActor @Sendable @escaping (Config) -> Void) -> DispatchSourceFileSystemObject? {
        let dirURL = configURL.deletingLastPathComponent()
        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.config.error("config watch: cannot open dir \(dirURL.path, privacy: .public) — errno=\(errno)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // .write covers normal saves, .delete/.rename catch atomic
            // replace patterns (vim's `:w`, VSCode, JetBrains all rename).
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler {
            // Always reload fresh — `loadOrSeedDefaults` reads the current
            // path, so even after a rename we'll see the new file.
            let config = loadOrSeedDefaults()
            MainActor.assumeIsolated {
                // If we just wrote the file ourselves (e.g. from the
                // Settings window), suppress the resulting reload. The
                // 500 ms window covers the OS-side fsevent latency without
                // accidentally swallowing a legitimate user edit that
                // lands on the same heartbeat.
                if let marker = selfWritingMarker, Date().timeIntervalSince(marker) < 0.5 {
                    selfWritingMarker = nil
                    return
                }
                onChange(config)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        Log.config.info("config watch: armed on \(dirURL.path, privacy: .public)")
        return source
    }
}

// MARK: - Layout resolution

enum LayoutResolver {
    /// Maps an input source ID (e.g. `com.apple.keylayout.Russian`) to the
    /// `idx` configured in `config.layouts`. Strips the suffix after the last
    /// dot and looks it up. Returns nil if not in the list.
    static func resolveIndex(inputSourceID: String, layouts: [String]) -> UInt8? {
        let suffix = inputSourceID.split(separator: ".").last.map(String.init) ?? inputSourceID
        guard let idx = layouts.firstIndex(of: suffix) else { return nil }
        return UInt8(idx)
    }
}

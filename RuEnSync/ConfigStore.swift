import CryptoKit
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

    /// A single per-app layout switching rule. `match` carries the matching
    /// criterion (exact bundle id or prefix); the sum type makes the dead
    /// "neither set" case unrepresentable at the schema level. `layout` is a
    /// suffix from `Config.layouts` — e.g. `"ABC"` or `"Russian"`.
    ///
    /// Codable round-trip preserves the old qmk-hid-host-style JSON shape
    /// (`bundleId` / `bundleIdPrefix`) — that's the on-disk format. The sum
    /// type only lives at runtime.
    struct AppLayoutRule: Equatable {
        // Two-level nesting (`Config.AppLayoutRule.Match`) violates
        // SwiftLint's default nesting cap of 1. We keep it nested anyway
        // because the type is meaningless outside its enclosing rule —
        // promoting it to `AppLayoutRuleMatch` at module scope would just
        // namespace-leak the matcher's vocabulary.
        // swiftlint:disable:next nesting
        enum Match: Equatable {
            case exact(String)
            case prefix(String)
        }

        var match: Match
        var layout: String

        var bundleId: String? {
            if case let .exact(id) = match { return id }
            return nil
        }

        var bundleIdPrefix: String? {
            if case let .prefix(p) = match { return p }
            return nil
        }
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
        // We do not provide a baked-in device list. The very first launch
        // runs auto-discovery (see AppModel.start). Shipping a sample
        // device that is only valid for one user's keyboard sent everyone
        // else into a misleading state where the device appears disconnected.
        devices: [],
        layouts: ["ABC", "Russian"],
        appLayoutRules: nil,
        appLayoutSwitchingEnabled: nil,
        debug: nil
    )
}

// MARK: - Config defaults

extension Config {
    /// Effective per-app switching flag — `nil` reads as `true` so adding
    /// rules to an existing config "just works" without also flipping a flag.
    /// Use this everywhere instead of `appLayoutSwitchingEnabled ?? true`.
    var effectiveAppLayoutSwitchingEnabled: Bool {
        appLayoutSwitchingEnabled ?? true
    }

    /// Effective HID inspector flag. `nil`/missing `debug` block reads as
    /// `false` (off by default).
    var effectiveHidInspectorEnabled: Bool {
        debug?.hidInspector ?? false
    }
}

// MARK: - AppLayoutRule constructors

extension Config.AppLayoutRule {
    /// Convenience for tests and rule-builders. Equivalent to writing
    /// `.init(match: .exact(bundleId), layout: layout)` but reads better.
    static func exact(_ bundleId: String, layout: String) -> Self {
        .init(match: .exact(bundleId), layout: layout)
    }

    /// Same idea for prefix rules.
    static func prefix(_ prefix: String, layout: String) -> Self {
        .init(match: .prefix(prefix), layout: layout)
    }
}

// MARK: - AppLayoutRule Codable (backward-compat)

extension Config.AppLayoutRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleId
        case bundleIdPrefix
        case layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        let bundleIdPrefix = try container.decodeIfPresent(String.self, forKey: .bundleIdPrefix)
        layout = try container.decode(String.self, forKey: .layout)
        // Exact wins over prefix when both present — same precedence the
        // legacy matcher used, so existing configs decode unchanged.
        if let bundleId, !bundleId.isEmpty {
            match = .exact(bundleId)
        } else if let bundleIdPrefix, !bundleIdPrefix.isEmpty {
            match = .prefix(bundleIdPrefix)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "AppLayoutRule must have either bundleId or bundleIdPrefix"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch match {
        case let .exact(id):
            try container.encode(id, forKey: .bundleId)
        case let .prefix(p):
            try container.encode(p, forKey: .bundleIdPrefix)
        }
        try container.encode(layout, forKey: .layout)
    }
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
    /// Outcome of a load attempt. Callers (notably AppModel) must distinguish
    /// these so that "first run" doesn't get conflated with "user's config is
    /// broken" — the latter must NEVER trigger auto-discovery, because that
    /// would overwrite the recoverable bad file with a discovery shell.
    enum LoadResult {
        case loaded(Config)
        case missing
        case corrupt(underlying: Error)
    }

    /// `~/.config/RuEnSync/config.json` — same layout as qmk-hid-host's path.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/RuEnSync/config.json")
    }

    /// Reads config.json from disk and classifies the outcome. The bad-file
    /// path **does not** rewrite or move anything — preserves user intent so
    /// they can debug. Pair with `seedDefaultIfMissing` to write the default
    /// on first run only.
    @MainActor
    static func load() -> LoadResult {
        let url = configURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            return .missing
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            // Track SHA of the on-disk content so the watcher can ignore the
            // fsevent for our own writes without a fragile time window.
            lastWrittenSHA = sha256(data)
            return .loaded(decoded)
        } catch {
            return .corrupt(underlying: error)
        }
    }

    /// Seeds the default config at `configURL` if (and only if) no file
    /// currently exists. No-op when the file is present, even if corrupt —
    /// callers must NEVER overwrite a broken config silently.
    @MainActor
    @discardableResult
    static func seedDefaultIfMissing() -> Bool {
        let url = configURL
        if FileManager.default.fileExists(atPath: url.path) {
            return false
        }
        do {
            try writeDefault(to: url)
            Log.config.info("seeded default config at \(url.path, privacy: .public)")
            return true
        } catch {
            let message = error.localizedDescription
            Log.config
                .error(
                    "failed to seed default config at \(url.path, privacy: .public): \(message, privacy: .public)"
                )
            return false
        }
    }

    /// Writes the default config JSON to `url`, creating parent dirs as needed.
    @MainActor
    static func writeDefault(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Config.default)
        try data.write(to: url, options: .atomic)
        lastWrittenSHA = sha256(data)
    }

    /// SHA-256 of the most recently written or loaded config. The watcher
    /// compares this against the on-disk SHA at fsevent time and suppresses
    /// reloads when they match — a cache-stamp scheme that survives bursty
    /// fsevents (atomic-rename produces multiple events) and slow disks
    /// without the 500 ms timing assumption the previous heuristic made.
    @MainActor private(set) static var lastWrittenSHA: String?

    /// Persists `config` atomically (temp-file + rename, same as
    /// `writeDefault`). Records the SHA of the bytes we just wrote so the
    /// file-watcher can ignore the resulting fsevent — see `watch(onChange:)`.
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
        lastWrittenSHA = sha256(data)
        try data.write(to: url, options: .atomic)
        Log.config.info("config saved to \(url.path, privacy: .public)")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Watches `~/.config/RuEnSync/` for changes and notifies the caller with
    /// the freshly classified `LoadResult` on each modification. Returns the
    /// source so the caller can keep it alive and cancel on teardown. We
    /// watch the **parent directory**, not the file itself, because most
    /// editors save through atomic write-temp-then-rename, which gives the
    /// original file a new inode and invalidates any FD held on it. Watching
    /// the dir survives that pattern.
    ///
    /// The watcher itself classifies each event:
    /// - if the on-disk SHA matches `lastWrittenSHA` → it's our own save,
    ///   suppressed (no callback fires).
    /// - if the file decodes cleanly → `.loaded(config)`.
    /// - if it parses-fails → `.corrupt`. **Crucially**, this does not get
    ///   conflated with `.missing`; the previous implementation collapsed
    ///   transient mid-edit decode failures into "config reverted to
    ///   defaults", which silently disconnected the keyboard.
    /// - if the file is gone (e.g. user is replacing it) → no callback;
    ///   we wait for the rename completion.
    static func watch(
        onChange: @MainActor @Sendable @escaping (LoadResult) -> Void
    ) -> DispatchSourceFileSystemObject? {
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
            let url = configURL
            // The mid-event file may briefly not exist (atomic rename window).
            // Wait for the next event in that case — don't surface .missing,
            // which would trigger a tear-down on every save by some editors.
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { return }
            let sha = sha256(data)
            MainActor.assumeIsolated {
                // Our own save — silently drop.
                if let last = lastWrittenSHA, sha == last { return }
                if let decoded = try? JSONDecoder().decode(Config.self, from: data) {
                    lastWrittenSHA = sha
                    onChange(.loaded(decoded))
                } else {
                    // Foreign decode failure: keep `lastWrittenSHA` untouched
                    // so we still detect when the user fixes the file.
                    let err = NSError(
                        domain: "ConfigStore",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "config.json failed to decode"]
                    )
                    onChange(.corrupt(underlying: err))
                }
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

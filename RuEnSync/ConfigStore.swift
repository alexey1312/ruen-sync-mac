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

    var devices: [Device]
    /// Ordered list of `TISPropertyInputSourceID` suffixes (the part after the
    /// last `.`). The index of the active layout in this array is sent as
    /// `data[1]` to the keyboard. Firmware treats `0 → EN`, anything else → RU.
    var layouts: [String]

    static let `default` = Config(
        devices: [
            .init(name: "Corne", productId: "0x0001", usagePage: nil, usage: nil),
        ],
        layouts: ["ABC", "Russian"]
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
        self.name = device.name
        self.productId = pid
        self.usagePage = device.usagePage ?? Self.qmkUsagePage
        self.usage = device.usage ?? Self.qmkUsage
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
                Log.config.error(
                    "failed to seed default config at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
            Log.config.error(
                "failed to parse config at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) — using defaults"
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

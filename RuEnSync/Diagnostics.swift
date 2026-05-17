import AppKit
import Foundation

// MARK: - Diagnostics

/// Bundles everything useful for a bug report into a single .zip in
/// ~/Downloads and reveals it in Finder. Designed to be called from a
/// background Task so the `Process` invocations don't block the menubar.
///
/// Contents:
/// - `system.txt`     — `sw_vers`, `sysctl hw.model`, app version.
/// - `config.json`    — copy of the user's config (productId is the only
///                      potentially sensitive bit and we leave it intact;
///                      the user can redact before sharing).
/// - `activity.db`    — full SQLite log (every event since first run).
/// - `log.txt`        — last hour of our subsystem from the unified log.
/// - `packets.txt`    — current ring-buffer contents (empty unless the
///                      inspector flag is on).
///
/// Errors are logged but never thrown to the UI — the caller gets the URL
/// of whatever subset of the bundle made it into the zip.
enum Diagnostics {
    static func exportZip(packetLog: HIDPacketLog) async -> URL? {
        // Snapshot the @MainActor-isolated log up-front. Everything below
        // can run off-main without crossing back, because we hold an
        // independent `[HIDPacketEntry]` value (Sendable by virtue of being
        // an immutable struct of Sendable fields).
        let packetSnapshot = await MainActor.run { packetLog.entries }

        let workDir = makeWorkDirectory()
        do {
            try writeSystemInfo(to: workDir.appendingPathComponent("system.txt"))
        } catch {
            Log.app.error("diagnostics: system.txt failed: \(error.localizedDescription, privacy: .public)")
        }
        copyIfExists(from: ConfigStore.configURL, to: workDir.appendingPathComponent("config.json"))
        copyIfExists(
            from: ConfigStore.configURL.deletingLastPathComponent().appendingPathComponent("activity.db"),
            to: workDir.appendingPathComponent("activity.db")
        )
        do {
            try await writeRecentLog(to: workDir.appendingPathComponent("log.txt"))
        } catch {
            Log.app.error("diagnostics: log.txt failed: \(error.localizedDescription, privacy: .public)")
        }
        writePacketSnapshot(packetSnapshot, to: workDir.appendingPathComponent("packets.txt"))

        let zipURL = downloadsZipURL()
        do {
            try await zip(workDir: workDir, to: zipURL)
            // Remove the temp dir; the zip itself lives in Downloads.
            try? FileManager.default.removeItem(at: workDir)
            return zipURL
        } catch {
            Log.app.error("diagnostics: zip failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Pieces

    private static func makeWorkDirectory() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ruensync-diag-\(stamp)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func downloadsZipURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("ruensync-diag-\(stamp).zip")
    }

    private static func writeSystemInfo(to url: URL) throws {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = (try? runShell("/usr/sbin/sysctl", arguments: ["-n", "hw.model"])) ?? "?"
        let lines = [
            "RuEnSync \(appVersion) (\(appBuild))",
            "macOS \(osVersion)",
            "Hardware: \(model)",
            "Generated: \(Date())",
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeRecentLog(to url: URL) async throws {
        let predicate = "subsystem == \"\(Log.subsystem)\""
        let output = try runShell(
            "/usr/bin/log",
            arguments: ["show", "--predicate", predicate, "--info", "--last", "1h", "--style", "compact"]
        )
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writePacketSnapshot(_ entries: [HIDPacketEntry], to url: URL) {
        guard !entries.isEmpty else { return }
        let lines = entries.map { entry -> String in
            let hex = entry.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let pid = String(format: "%04X", entry.productId)
            return "\(entry.timestamp)  \(entry.deviceName) (pid=0x\(pid))  \(entry.interpretation)\n  \(hex)"
        }
        try? lines.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func zip(workDir: URL, to zipURL: URL) async throws {
        // -r recursive, -j junk paths (don't store the tmp dir prefix), -q quiet.
        _ = try runShell(
            "/usr/bin/zip",
            arguments: ["-r", "-j", "-q", zipURL.path, workDir.path]
        )
    }

    private static func copyIfExists(from source: URL, to dest: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        try? fm.copyItem(at: source, to: dest)
    }

    /// Synchronous Process runner. Returns stdout as UTF-8 string. Throws on
    /// non-zero exit (including stderr in the error message).
    @discardableResult
    private static func runShell(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "Diagnostics", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(executable) exited \(process.terminationStatus): \(errStr)",
            ])
        }
        return outStr
    }
}

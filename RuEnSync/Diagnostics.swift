import AppKit
import Foundation
import SQLite

// MARK: - DiagnosticsResult

/// Outcome of `Diagnostics.exportZip`. The UI surfaces `missing` / `errors`
/// to the user so a bug report that ships without `activity.db` doesn't get
/// noticed only on the receiving end. `nil` zipURL means we couldn't even
/// produce the archive — show `errors` directly.
struct DiagnosticsResult {
    let zipURL: URL?
    /// Files that should have been in the bundle but weren't (source missing
    /// or copy/write failed). Human-readable names like `"config.json"`.
    let missing: [String]
    /// Underlying errors collected during the export. Logged at `.error`
    /// already; included here so the caller can surface a one-line summary.
    let errors: [Error]
}

extension Diagnostics {
    /// Standard caller-side response to an export result: reveal the zip in
    /// Finder if we produced one, set `lastSettingsError` on the model when
    /// anything went missing or failed so the user sees a banner instead of
    /// having to find this in Console. Centralised here so both the Settings
    /// "Export diagnostics…" button and the menubar "Export diagnostics…"
    /// menu item behave identically.
    @MainActor
    static func handleExportResult(_ result: DiagnosticsResult, surfaceTo model: AppModel) {
        if let url = result.zipURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if !result.missing.isEmpty || !result.errors.isEmpty {
            let missingPart = result.missing.isEmpty ? "" : " Missing: \(result.missing.joined(separator: ", "))."
            let errorPart = result.errors.isEmpty ? "" : " Errors: \(result.errors.count)."
            model.lastSettingsError = String(
                localized: "Diagnostics export completed with issues.\(missingPart)\(errorPart) See log for details."
            )
        }
    }
}

// MARK: - Diagnostics

/// Bundles everything useful for a bug report into a single .zip in
/// ~/Downloads and reveals it in Finder. Designed to be called from a
/// background Task so the `Process` invocations don't block the menubar.
///
/// Contents:
/// - `README.txt`     — short description of each file, plus a privacy
///                      hint about `appLayoutRules` carrying bundle IDs.
/// - `system.txt`     — `ProcessInfo.operatingSystemVersionString`,
///                      `sysctl hw.model`, app version + build.
/// - `config.json`    — copy of the user's config. `productId` is the
///                      only protocol-relevant field; `appLayoutRules`
///                      reveals which apps the user has rules for, so
///                      the user may want to redact before sharing.
/// - `activity.db`    — full SQLite log (every event since first run).
///                      WAL-checkpointed before copy so the snapshot is
///                      complete.
/// - `log.txt`        — last hour of our subsystem from the unified log.
/// - `packets.txt`    — current ring-buffer contents (empty unless the
///                      inspector flag is on).
enum Diagnostics {
    // swiftlint:disable:next cyclomatic_complexity
    static func exportZip(packetLog: HIDPacketLog) async -> DiagnosticsResult {
        // Snapshot the @MainActor-isolated log up-front. Everything below
        // can run off-main without crossing back, because we hold an
        // independent `[HIDPacketEntry]` value (Sendable by virtue of being
        // an immutable struct of Sendable fields).
        let packetSnapshot = await MainActor.run { packetLog.entries }
        // Checkpoint the WAL so the on-disk activity.db reflects all recent
        // writes. Without this the user's last-hour bug-report context could
        // sit in `activity.db-wal` and never make it into the zip.
        checkpointActivityDBIfPresent()

        var missing: [String] = []
        var errors: [Error] = []

        let workDir = makeWorkDirectory()

        do {
            try await writeReadme(to: workDir.appendingPathComponent("README.txt"))
        } catch {
            errors.append(error)
            missing.append("README.txt")
            Log.app.error("diagnostics: README.txt failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await writeSystemInfo(to: workDir.appendingPathComponent("system.txt"))
        } catch {
            errors.append(error)
            missing.append("system.txt")
            Log.app.error("diagnostics: system.txt failed: \(error.localizedDescription, privacy: .public)")
        }

        // config.json + activity.db copies. Distinguish "source missing"
        // (legitimate first-run case) from "copy failed" (the user will
        // want to know — that's the file the bug report needed).
        switch await copyIfExists(from: ConfigStore.configURL, to: workDir.appendingPathComponent("config.json")) {
        case .copied: break
        case .sourceMissing: break // no config yet: not a bug, not flagged.
        case let .failed(error):
            errors.append(error)
            missing.append("config.json")
        }

        let dbSrc = ConfigStore.configURL.deletingLastPathComponent().appendingPathComponent("activity.db")
        switch await copyIfExists(from: dbSrc, to: workDir.appendingPathComponent("activity.db")) {
        case .copied: break
        case .sourceMissing: break
        case let .failed(error):
            errors.append(error)
            missing.append("activity.db")
        }

        do {
            try await writeRecentLog(to: workDir.appendingPathComponent("log.txt"))
        } catch {
            errors.append(error)
            missing.append("log.txt")
            Log.app.error("diagnostics: log.txt failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await writePacketSnapshot(packetSnapshot, to: workDir.appendingPathComponent("packets.txt"))
        } catch {
            errors.append(error)
            // packets.txt is only meaningful when the inspector is on; the
            // empty-snapshot path doesn't even attempt a write — so a
            // logged error here is a real I/O failure worth surfacing.
            missing.append("packets.txt")
            Log.app.error("diagnostics: packets.txt failed: \(error.localizedDescription, privacy: .public)")
        }

        let zipURL = downloadsZipURL()
        do {
            try await zip(workDir: workDir, to: zipURL)
            try? FileManager.default.removeItem(at: workDir)
            return DiagnosticsResult(zipURL: zipURL, missing: missing, errors: errors)
        } catch {
            errors.append(error)
            Log.app.error("diagnostics: zip failed: \(error.localizedDescription, privacy: .public)")
            return DiagnosticsResult(zipURL: nil, missing: missing, errors: errors)
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

    /// Opens an ad-hoc connection to the activity DB and flushes the WAL
    /// into the main file. No-op when the DB doesn't exist (no entries
    /// yet). We open our own connection rather than reusing the live
    /// `ActivityStore.database` so this can run off the main actor without
    /// crossing isolation boundaries; SQLite's default serialized threading
    /// mode makes the cross-handle checkpoint safe.
    private static func checkpointActivityDBIfPresent() {
        let path = ConfigStore.configURL.deletingLastPathComponent()
            .appendingPathComponent("activity.db").path
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let conn = try Connection(path)
            try conn.execute("PRAGMA wal_checkpoint(FULL)")
        } catch {
            Log.app
                .error(
                    "diagnostics: WAL checkpoint failed: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    private static func writeReadme(to url: URL) async throws {
        let body = """
        RuEnSync diagnostics bundle
        ===========================

        Contents:
          system.txt     macOS version, hardware model, app version.
          config.json    your ~/.config/RuEnSync/config.json. Note that this
                         file lists app bundle IDs from `appLayoutRules`
                         (which apps you have layout rules for) — feel free
                         to redact these before sharing the bundle.
          activity.db    SQLite log of every event since first run.
          log.txt        last hour of unified-log entries from
                         com.alexey1312.ruensync.
          packets.txt    recent HID packets (empty unless the HID Inspector
                         is enabled in Settings → Debug).

        If a file you expect to see is missing, the host app's status sheet
        will have flagged it — that means the export tried and failed (not
        that the export forgot it).
        """
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func writeSystemInfo(to url: URL) async throws {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = await (try? runShell("/usr/sbin/sysctl", arguments: ["-n", "hw.model"])) ?? "?"
        let lines = [
            "RuEnSync \(appVersion) (\(appBuild))",
            "macOS \(osVersion)",
            "Hardware: \(model)",
            "Generated: \(Date())",
        ]
        let text = lines.joined(separator: "\n")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func writeRecentLog(to url: URL) async throws {
        let predicate = "subsystem == \"\(Log.subsystem)\""
        let output = try await runShell(
            "/usr/bin/log",
            arguments: ["show", "--predicate", predicate, "--info", "--last", "1h", "--style", "compact"]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try output.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func writePacketSnapshot(_ entries: [HIDPacketEntry], to url: URL) async throws {
        guard !entries.isEmpty else { return }
        let lines = entries.map { entry -> String in
            let hex = entry.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let pid = String(format: "%04X", entry.productId)
            return "\(entry.timestamp)  \(entry.deviceName) (pid=0x\(pid))  \(entry.interpretation)\n  \(hex)"
        }
        let text = lines.joined(separator: "\n\n")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func zip(workDir: URL, to zipURL: URL) async throws {
        // -r recursive, -j junk paths (don't store the tmp dir prefix), -q quiet.
        _ = try await runShell(
            "/usr/bin/zip",
            arguments: ["-r", "-j", "-q", zipURL.path, workDir.path]
        )
    }

    /// Result of a defensive copy. Splits the previous "silently swallow
    /// errors" path into something the caller can react to.
    private enum CopyOutcome {
        case copied
        case sourceMissing
        case failed(Error)
    }

    private static func copyIfExists(from source: URL, to dest: URL) async -> CopyOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return .sourceMissing }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try fm.copyItem(at: source, to: dest)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            return .copied
        } catch {
            Log.app
                .error(
                    "diagnostics: copy \(source.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            return .failed(error)
        }
    }

    /// Async Process runner. Returns stdout as UTF-8 string. Throws on
    /// non-zero exit (including stderr in the error message).
    ///
    /// Drains stdout and stderr **concurrently** before `waitUntilExit`
    /// completes. The naive "run → wait → readDataToEndOfFile" sequence
    /// deadlocks once the child writes more than the pipe buffer (~64 KB
    /// on macOS): the child blocks on `write()` and the parent blocks on
    /// `waitUntilExit()`, neither side makes progress. `log show
    /// --info --last 1h` routinely exceeds that threshold for users with
    /// any non-trivial activity, so the previous synchronous variant
    /// was a latent freeze.
    @discardableResult
    private static func runShell(_ executable: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Detached Tasks so each pipe drains independently. Once both
        // return EOF the child has closed its end (and therefore exited),
        // so `waitUntilExit` is a non-blocking reaper that just publishes
        // `terminationStatus`.
        async let outDataTask: Data = Task.detached(priority: .userInitiated) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let errDataTask: Data = Task.detached(priority: .userInitiated) {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }.value
        let outData = await outDataTask
        let errData = await errDataTask
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            if !process.isRunning {
                process.terminationHandler = nil
                continuation.resume()
            }
        }

        let outStr = String(data: outData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "Diagnostics", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(executable) exited \(process.terminationStatus): \(errStr)",
            ])
        }
        return outStr
    }
}

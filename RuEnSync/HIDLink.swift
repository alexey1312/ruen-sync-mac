import Foundation
import IOKit
import IOKit.hid
import os

// MARK: - HIDLink

/// Owns an `IOHIDManager` filtered to the configured Raw HID interface
/// (UsagePage 0xFF60, Usage 0x61, ProductID = config.productId). Sends one
/// 32-byte Output Report per layout change (see `reportSize`; CLAUDE.md §4
/// has the full byte-count rationale). Bit-for-bit identical to
/// qmk-hid-host's wire format for `_LAYOUT`, so any unmodified Vial-QMK
/// firmware listening for `[0xAC, idx, …]` accepts our packets.
///
/// Beyond `qmk-hid-host`, we also push a one-shot `_OS_TYPE` packet
/// (`[0xB0, 'M', 'A', 'C', 0x00, …]`) immediately on every device connect.
/// Firmware that knows this data_type can flip into its macOS-Russian variant
/// without manual EEPROM toggling after a reflash; firmware that doesn't ignores
/// the unknown data_type and behaves exactly as before.
///
/// Threading: all IOHIDManager callbacks land on the main run loop because we
/// schedule onto `CFRunLoopGetMain()`. The owner (AppModel) is `@MainActor`,
/// so we deliver state changes via a simple delegate-style closure.
@MainActor
final class HIDLink {
    // MARK: State

    /// Single source of truth for "is this device usable?". Carrying the
    /// reason inside `.offline` makes impossible pairs (connected + reason,
    /// offline without reason) unrepresentable — every state transition is
    /// one assignment, and every UI consumer pattern-matches one value.
    enum State: Equatable {
        case offline(reason: OfflineReason)
        case connected(productId: UInt32)
    }

    /// Why we are currently offline. Surfaced in the menubar so users know
    /// whether to plug the keyboard in, kill a conflicting daemon, or file
    /// a bug.
    enum OfflineReason: Equatable {
        /// We just started up and IOKit hasn't matched any device yet, OR the
        /// keyboard is physically unplugged. Indistinguishable from here.
        case awaitingDevice
        /// Another process (typically `qmk-hid-host`) holds exclusive access.
        case exclusiveAccess
        /// `IOHIDDeviceOpen` failed for some other reason. Includes the raw
        /// `IOReturn` code so we can surface a hex string.
        case openFailed(code: Int32)
        /// `IOHIDManagerOpen` failed at startup — usually a permissions issue
        /// or an OS bug. Includes the raw `IOReturn` code.
        case managerOpenFailed(code: Int32)
    }

    private(set) var state: State = .offline(reason: .awaitingDevice)
    var onStateChange: ((State) -> Void)?

    /// When non-nil and `inspectionEnabled` is true, every successful
    /// `send` copies the 32-byte report into the log. Both fields are set
    /// by AppModel — HIDLink doesn't read the config directly.
    var packetLog: HIDPacketLog?
    var inspectionEnabled: Bool = false

    // MARK: Configuration

    let device: ResolvedDevice
    private let manager: IOHIDManager
    private var openedDevice: IOHIDDevice?
    private var hasStarted = false
    /// Opaque pointer to `Unmanaged.passRetained(self)` handed to IOKit
    /// callbacks. Released in `stop()` to balance the retain — kept here so
    /// we have a handle to release exactly once.
    private var callbackContext: UnsafeMutableRawPointer?

    // MARK: Protocol constants (immutable; safe to access nonisolated)

    /// `_LAYOUT` data type from qmk-hid-host's `data_type.rs`. Firmware in
    /// `firmware/crkbd.c.patch` matches on this exact byte at offset 1 of the
    /// HID report (offset 0 is the report ID, which is what hidapi convention
    /// places it at, and what `IOHIDDeviceSetReport` expects).
    nonisolated static let layoutDataType: UInt8 = 0xAC

    /// `_OS_TYPE` — RuEnSync-specific extension. Chosen as 0xB0 because
    /// qmk-hid-host's macOS build uses up to 0xAF (Weather) and its Linux
    /// build uses 0xAD/0xAE (MediaArtist/MediaTitle), so 0xB0 is the first
    /// byte safely free across all qmk-hid-host platforms.
    ///
    /// Wire-compat note: we reuse the 4-byte ASCII OS magic from
    /// `nomis/qmk-hid-identify` (`MAC\0` / `LNX\0` / `WIN\0` / `BSD\0`), but
    /// NOT nomis's full wire format — nomis prefixes packets with
    /// `[0x00, 0x01]` rather than a data_type byte, so a stock nomis
    /// dispatcher will not pick up our packet. The
    /// `split_keyboard_layouts/firmware/crkbd.c.patch` matches our `0xB0`
    /// directly.
    nonisolated static let osTypeDataType: UInt8 = 0xB0

    /// `MAC\0` magic borrowed from `nomis/qmk-hid-identify`. RuEnSync is
    /// macOS-only, so this is the only magic we ever send.
    nonisolated static let osMagicMac: [UInt8] = [0x4D, 0x41, 0x43, 0x00]

    /// QMK Raw HID Interrupt OUT endpoint expects exactly `RAW_EPSIZE` (32)
    /// bytes. Unlike hidapi (which strips a leading report-ID byte before
    /// writing), `IOHIDDeviceSetReport` sends the buffer as-is per Apple's
    /// docs. With reportID = 0 (unnumbered report), the buffer must therefore
    /// start directly with the data — no leading `0x00`. A 33-byte buffer
    /// would either be split into 32 + 1 packets or truncated by USB, and
    /// the firmware would parse `data[0] = 0x00` and silently drop the packet.
    nonisolated static let reportSize: Int = 32

    // MARK: Init

    init(device: ResolvedDevice) {
        self.device = device
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: Public API

    /// Starts the IOHIDManager with our matching dict and registers
    /// device-matching / removal callbacks. Idempotent: calling `start` twice
    /// is a no-op (manager keeps its existing schedule).
    func start() {
        if hasStarted { return }
        hasStarted = true

        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: NSNumber(value: device.usagePage),
            kIOHIDPrimaryUsageKey: NSNumber(value: device.usage),
            kIOHIDProductIDKey: NSNumber(value: device.productId),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        // Pass `self` as a retained context. AppModel.reconnectAll() drops the
        // strong reference to this HIDLink before tearing down the manager, so
        // an unretained pointer could read freed memory if IOKit dispatches a
        // matched/removed callback in that window. The matching `release()` is
        // in `stop()` once the manager is closed and no further callbacks can
        // fire.
        let context = Unmanaged.passRetained(self).toOpaque()
        callbackContext = context

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, ioDevice in
            guard let ctx else { return }
            let link = Unmanaged<HIDLink>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { link.handleDeviceMatched(ioDevice) }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, ioDevice in
            guard let ctx else { return }
            let link = Unmanaged<HIDLink>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { link.handleDeviceRemoved(ioDevice) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            let code = String(format: "0x%08X", result)
            Log.hid.error("IOHIDManagerOpen failed: \(code, privacy: .public)")
            transitionToOffline(reason: .managerOpenFailed(code: result))
        } else {
            let pid = String(format: "0x%04X", device.productId)
            let page = String(format: "0x%04X", device.usagePage)
            let usage = String(format: "0x%04X", device.usage)
            Log.hid
                .info(
                    "watching pid=\(pid, privacy: .public) usagePage=\(page, privacy: .public) usage=\(usage, privacy: .public)"
                )
        }
    }

    /// Sends a layout-change packet. `idx == 0` means EN, anything else means
    /// RU (firmware contract). No-op if no device is currently connected.
    @discardableResult
    func send(layoutIndex: UInt8) -> Bool {
        let report = Self.buildReport(layoutIndex: layoutIndex)
        guard sendReport(report, label: "idx=\(layoutIndex)") else { return false }
        return true
    }

    /// Sends a one-shot `_OS_TYPE` packet with `MAC\0` magic. Called by
    /// AppModel immediately after every successful connect — that way
    /// firmware that supports the new data_type wakes up in Mac mode without
    /// the user touching the keyboard.
    @discardableResult
    func sendOSFlag() -> Bool {
        let report = Self.buildOSReport()
        return sendReport(report, label: "OS=MAC")
    }

    // MARK: Internal send

    private func sendReport(_ report: [UInt8], label: String) -> Bool {
        guard let opened = openedDevice else {
            Log.hid.debug("send(\(label, privacy: .public)) ignored — device not connected")
            return false
        }

        var buffer = report
        let result = IOHIDDeviceSetReport(
            opened,
            kIOHIDReportTypeOutput,
            0, // report ID matches byte 0
            &buffer,
            buffer.count
        )

        if result == kIOReturnSuccess {
            return handleSendSuccess(buffer: buffer, label: label)
        }
        return handleSendFailure(result: result, label: label, opened: opened)
    }

    private func handleSendSuccess(buffer: [UInt8], label: String) -> Bool {
        let pid = String(format: "0x%04X", device.productId)
        Log.hid.info("sent \(label, privacy: .public) to pid=\(pid, privacy: .public)")
        // Inspection log: gated on a per-link flag rather than a per-send
        // config lookup so the hot path stays cheap. AppModel flips the
        // flag on every config reload to keep it in sync.
        if inspectionEnabled, let packetLog {
            packetLog.record(deviceName: device.name, productId: device.productId, bytes: buffer)
        }
        return true
    }

    private func handleSendFailure(result: IOReturn, label: String, opened: IOHIDDevice) -> Bool {
        let code = String(format: "0x%08X", result)
        let pid = String(format: "0x%04X", device.productId)
        Log.hid
            .error(
                "IOHIDDeviceSetReport failed: \(code, privacy: .public) for \(label, privacy: .public) pid=\(pid, privacy: .public)"
            )
        // Any non-success means this transport is broken: kIOReturnNotOpen /
        // NoDevice / NotAttached are obvious removals; kIOReturnError / Timeout
        // / Aborted / NotResponding indicate a stalled endpoint or unplugged
        // hub. Staying "connected" in the menubar while reports silently fail
        // is worse than going offline — IOKit will refire device-matched if
        // and when the keyboard reappears, and the user can hit Reconnect.
        IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeNone))
        openedDevice = nil
        let reason: OfflineReason = (result == kIOReturnExclusiveAccess)
            ? .exclusiveAccess
            : .openFailed(code: result)
        transitionToOffline(reason: reason)
        return false
    }

    // MARK: Callbacks

    private func handleDeviceMatched(_ ioDevice: IOHIDDevice) {
        if let already = openedDevice, CFEqual(already, ioDevice) {
            return
        }
        // QMK keyboards typically have multiple HID interfaces (keyboard,
        // mouse, consumer, raw); IOHIDManager already filtered by our matching
        // dict, so any matched device IS our Raw HID interface.
        let result = IOHIDDeviceOpen(ioDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            let code = String(format: "0x%08X", result)
            Log.hid
                .error("IOHIDDeviceOpen failed: \(code, privacy: .public) — may be held by another app (qmk-hid-host?)")
            let reason: OfflineReason = (result == kIOReturnExclusiveAccess)
                ? .exclusiveAccess
                : .openFailed(code: result)
            transitionToOffline(reason: reason)
            return
        }
        openedDevice = ioDevice
        state = .connected(productId: device.productId)
        let pid = String(format: "0x%04X", device.productId)
        Log.hid.info("matched device pid=\(pid, privacy: .public)")
        onStateChange?(state)
    }

    private func handleDeviceRemoved(_ ioDevice: IOHIDDevice) {
        guard let opened = openedDevice, CFEqual(opened, ioDevice) else { return }
        IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeNone))
        openedDevice = nil
        let pid = String(format: "0x%04X", device.productId)
        Log.hid.info("device removed pid=\(pid, privacy: .public)")
        transitionToOffline(reason: .awaitingDevice)
    }

    private func transitionToOffline(reason: OfflineReason) {
        state = .offline(reason: reason)
        onStateChange?(state)
    }

    // MARK: Lifecycle

    /// Tears down the IOHIDManager. We expose this explicitly instead of
    /// running it from `deinit` because `deinit` is always `nonisolated` in
    /// Swift 6, and IOHIDDevice/IOHIDManager are non-Sendable Core Foundation
    /// types we hold from a `@MainActor` class. In practice HIDLink lives for
    /// the entire app process so this is rarely called — but it keeps the
    /// shutdown path correct.
    func stop() {
        if let opened = openedDevice {
            IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeNone))
            openedDevice = nil
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        // Balance the retain from `start()`. After IOHIDManagerClose, no
        // further matching/removal callbacks can fire — safe to release.
        if let ctx = callbackContext {
            Unmanaged<HIDLink>.fromOpaque(ctx).release()
            callbackContext = nil
        }
    }
}

// MARK: - Helpers

extension HIDLink {
    /// Builds the wire-format layout report. Pure function, exposed for unit
    /// tests and identical to what `send(layoutIndex:)` writes to the device.
    /// Layout: `[0xAC, idx, 0, 0, …]` — 32 bytes total. Firmware checks
    /// `data[0] == 0xAC`, so byte 0 is the data-type, not a report-ID prefix.
    nonisolated static func buildReport(layoutIndex: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = layoutDataType
        report[1] = layoutIndex
        return report
    }

    /// Builds the wire-format `_OS_TYPE` report. `[0xB0, 'M', 'A', 'C',
    /// 0x00, …]` — 32 bytes total. Pure function, exposed for unit tests.
    nonisolated static func buildOSReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = osTypeDataType
        for (offset, byte) in osMagicMac.enumerated() {
            report[1 + offset] = byte
        }
        return report
    }
}

// MARK: - Display helpers

extension HIDLink.OfflineReason {
    /// Human-readable label for the menubar. Kept short — surfaces in a
    /// secondary-color caption row, not a sentence. Localized via the
    /// String catalog so non-English macOS users get a native label.
    var menuLabel: String {
        switch self {
        case .awaitingDevice:
            String(localized: "Not connected")
        case .exclusiveAccess:
            String(localized: "Device busy (qmk-hid-host running?)")
        case let .openFailed(code):
            String(localized: "Open failed (\(String(format: "0x%08X", code)))")
        case let .managerOpenFailed(code):
            String(localized: "HID manager open failed (\(String(format: "0x%08X", code)))")
        }
    }

    /// True if the offline reason can plausibly clear itself on a re-open
    /// attempt — e.g. another app (Vial) released its exclusive lock, the
    /// kernel ungated a transient error. `awaitingDevice` is excluded because
    /// IOHIDManager re-fires `handleDeviceMatched` automatically on replug,
    /// so retrying ourselves would just thrash without changing anything.
    var isRecoverable: Bool {
        switch self {
        case .awaitingDevice:
            false
        case .exclusiveAccess, .openFailed, .managerOpenFailed:
            true
        }
    }
}

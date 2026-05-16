import Foundation
import IOKit
import IOKit.hid
import os

// MARK: - HIDLink

/// Owns an `IOHIDManager` filtered to the configured Raw HID interface
/// (UsagePage 0xFF60, Usage 0x61, ProductID = config.productId). Sends one
/// 33-byte Output Report per layout change. Bit-for-bit identical to
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

    enum State: Equatable {
        case offline
        case connected(productId: UInt32)
    }

    /// Why we are currently offline. `nil` while connected. Surfaced in the
    /// menubar so users know whether to plug the keyboard in, kill a
    /// conflicting daemon, or file a bug.
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

    private(set) var state: State = .offline
    private(set) var offlineReason: OfflineReason? = .awaitingDevice
    var onStateChange: ((State) -> Void)?

    // MARK: Configuration

    let device: ResolvedDevice
    private let manager: IOHIDManager
    private var openedDevice: IOHIDDevice?
    private var hasStarted = false

    // MARK: Protocol constants (immutable; safe to access nonisolated)

    /// `_LAYOUT` data type from qmk-hid-host's `data_type.rs`. Firmware in
    /// `firmware/crkbd.c.patch` matches on this exact byte at offset 1 of the
    /// HID report (offset 0 is the report ID, which is what hidapi convention
    /// places it at, and what `IOHIDDeviceSetReport` expects).
    nonisolated static let layoutDataType: UInt8 = 0xAC

    /// `_OS_TYPE` — RuEnSync-specific extension. Chosen as 0xB0 because
    /// qmk-hid-host's macOS build uses up to 0xAF (Weather), so 0xB0 is the
    /// first safely-free byte that won't collide with any qmk-hid-host
    /// payload across any platform. Payload is a 4-byte ASCII magic compatible
    /// with `nomis/qmk-hid-identify` (`MAC\0` / `LNX\0` / `WIN\0` / `BSD\0`).
    nonisolated static let osTypeDataType: UInt8 = 0xB0

    /// `MAC\0` magic from `nomis/qmk-hid-identify`. RuEnSync is macOS-only,
    /// so this is the only magic we ever send.
    nonisolated static let osMagicMac: [UInt8] = [0x4D, 0x41, 0x43, 0x00]

    /// QMK `RAW_EPSIZE` = 32 bytes payload, plus 1 byte report ID prefix = 33.
    nonisolated static let reportSize: Int = 33

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

        // Pass `self` as unretained context. We are `@MainActor`-bound and
        // schedule callbacks onto the main run loop, so unretained is safe —
        // HIDLink outlives the manager (we deinit before the manager goes).
        let context = Unmanaged.passUnretained(self).toOpaque()

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

    /// Tears down and immediately restarts. Wired to the "Reconnect" menu
    /// button — gives users a way to recover after killing a conflicting
    /// daemon (e.g. qmk-hid-host) without restarting the whole app.
    func reconnect() {
        stop()
        hasStarted = false
        // Manager handle is dead after `stop()`; the field is `let`, so the
        // proper restart path is on the AppModel side (re-create HIDLink).
        // We expose `reconnect()` mainly so AppModel can implement that via a
        // single call; see `AppModel.reconnectAll()`.
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
            Log.hid.info("sent \(label, privacy: .public)")
            return true
        }
        let code = String(format: "0x%08X", result)
        Log.hid.error("IOHIDDeviceSetReport failed: \(code, privacy: .public) for \(label, privacy: .public)")
        // The device disappeared or stopped accepting reports. Drop our handle
        // and go offline so the menubar reflects reality; IOKit will refire
        // device-matched if/when the keyboard comes back. (Better than the
        // previous silent-drop: the user would have seen "connected" while
        // nothing was actually getting through.)
        if result == kIOReturnNotOpen || result == kIOReturnNoDevice {
            IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeNone))
            openedDevice = nil
            transitionToOffline(reason: .openFailed(code: result))
        }
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
        offlineReason = nil
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
        state = .offline
        offlineReason = reason
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
    }
}

// MARK: - Helpers

extension HIDLink {
    /// Builds the wire-format layout report. Pure function, exposed for unit
    /// tests and identical to what `send(layoutIndex:)` writes to the device.
    nonisolated static func buildReport(layoutIndex: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = 0x00
        report[1] = layoutDataType
        report[2] = layoutIndex
        return report
    }

    /// Builds the wire-format `_OS_TYPE` report. `[0x00, 0xB0, 'M', 'A', 'C',
    /// 0x00, …]`. Pure function, exposed for unit tests.
    nonisolated static func buildOSReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = 0x00
        report[1] = osTypeDataType
        for (offset, byte) in osMagicMac.enumerated() {
            report[2 + offset] = byte
        }
        return report
    }
}

// MARK: - Display helpers

extension HIDLink.OfflineReason {
    /// Human-readable label for the menubar. Kept short — surfaces in a
    /// secondary-color caption row, not a sentence.
    var menuLabel: String {
        switch self {
        case .awaitingDevice:
            "Not connected"
        case .exclusiveAccess:
            "Device busy (qmk-hid-host running?)"
        case let .openFailed(code):
            "Open failed (\(String(format: "0x%08X", code)))"
        case let .managerOpenFailed(code):
            "HID manager open failed (\(String(format: "0x%08X", code)))"
        }
    }
}

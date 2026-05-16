import Foundation
import IOKit
import IOKit.hid
import os

// MARK: - HIDLink

/// Owns an `IOHIDManager` filtered to the configured Raw HID interface
/// (UsagePage 0xFF60, Usage 0x61, ProductID = config.productId). Sends one
/// 33-byte Output Report per layout change. Bit-for-bit identical to
/// qmk-hid-host's wire format, so any unmodified Vial-QMK firmware listening
/// for `[0xAC, idx, …]` accepts our packets.
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

    private(set) var state: State = .offline
    var onStateChange: ((State) -> Void)?

    // MARK: Configuration

    private let device: ResolvedDevice
    private let manager: IOHIDManager
    private var openedDevice: IOHIDDevice?

    // MARK: Protocol constants (immutable; safe to access nonisolated)

    /// `_LAYOUT` data type from qmk-hid-host's `data_type.rs`. Firmware in
    /// `firmware/crkbd.c.patch` matches on this exact byte at offset 1 of the
    /// HID report (offset 0 is the report ID, which is what hidapi convention
    /// places it at, and what `IOHIDDeviceSetReport` expects).
    nonisolated static let layoutDataType: UInt8 = 0xAC

    /// QMK `RAW_EPSIZE` = 32 bytes payload, plus 1 byte report ID prefix = 33.
    nonisolated static let reportSize: Int = 33

    // MARK: Init

    init(device: ResolvedDevice) {
        self.device = device
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: Public API

    /// Starts the IOHIDManager with our matching dict and registers
    /// device-matching / removal callbacks. Idempotent: calling `start` twice
    /// is a no-op (manager keeps its existing schedule).
    func start() {
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
            Log.hid.error("IOHIDManagerOpen failed: \(String(format: "0x%08X", result), privacy: .public)")
        } else {
            Log.hid.info(
                "watching for HID device pid=\(String(format: "0x%04X", self.device.productId), privacy: .public) usagePage=\(String(format: "0x%04X", self.device.usagePage), privacy: .public) usage=\(String(format: "0x%04X", self.device.usage), privacy: .public)"
            )
        }
    }

    /// Sends a layout-change packet. `idx == 0` means EN, anything else means
    /// RU (firmware contract). No-op if no device is currently connected.
    @discardableResult
    func send(layoutIndex: UInt8) -> Bool {
        guard let opened = openedDevice else {
            Log.hid.debug("send(\(layoutIndex)) ignored — device not connected")
            return false
        }

        var report = [UInt8](repeating: 0, count: Self.reportSize)
        report[0] = 0x00 // report ID
        report[1] = Self.layoutDataType
        report[2] = layoutIndex

        let result = IOHIDDeviceSetReport(
            opened,
            kIOHIDReportTypeOutput,
            0, // report ID matches byte 0
            &report,
            report.count
        )

        if result == kIOReturnSuccess {
            Log.hid.info("sent idx=\(layoutIndex)")
            return true
        }
        Log.hid.error(
            "IOHIDDeviceSetReport failed: \(String(format: "0x%08X", result), privacy: .public)"
        )
        // TODO(USER_INPUT): decide error-handling strategy here. See README.
        // Options: silently drop and wait for next switch; tear down + reopen
        // the device; show error in menubar. For now we drop and continue.
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
            Log.hid.error(
                "IOHIDDeviceOpen failed: \(String(format: "0x%08X", result), privacy: .public) — may be held by another app (qmk-hid-host?)"
            )
            return
        }
        openedDevice = ioDevice
        state = .connected(productId: device.productId)
        Log.hid.info("matched device pid=\(String(format: "0x%04X", self.device.productId), privacy: .public)")
        onStateChange?(state)
    }

    private func handleDeviceRemoved(_ ioDevice: IOHIDDevice) {
        guard let opened = openedDevice, CFEqual(opened, ioDevice) else { return }
        IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeNone))
        openedDevice = nil
        state = .offline
        Log.hid.info("device removed pid=\(String(format: "0x%04X", self.device.productId), privacy: .public)")
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
    /// Builds the wire-format report. Pure function, exposed for unit tests
    /// and identical to what `send(layoutIndex:)` writes to the device.
    nonisolated static func buildReport(layoutIndex: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = 0x00
        report[1] = layoutDataType
        report[2] = layoutIndex
        return report
    }
}

# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this repo is

A native macOS menubar app that keeps a QMK keyboard's `cur_lang` in sync with the
active macOS input source. Drop-in replacement for [qmk-hid-host](https://github.com/zzeneg/qmk-hid-host),
written specifically for the
[split_keyboard_layouts](https://github.com/alexey1312/split_keyboard_layouts) Corne firmware.

## Stack

- **Tuist** (`Project.swift`, `Tuist.swift`) generates the Xcode project. No checked-in
  `.xcodeproj` — regenerate with `mise run generate`.
- **Swift 6** with strict concurrency. macOS 26 minimum.
- **SwiftUI** `MenuBarExtra` (the new declarative menubar API).
- **mise** drives all tasks (build, test, lint, format, release). See `mise.toml`.
- **hk + pkl** for git hooks (pre-commit auto-formats + lints).
- **dprint** for markdown formatting.

There is **no** SPM Package.swift, no CocoaPods, no Carthage. All dependencies are
system frameworks (Carbon, IOKit, AppKit/SwiftUI, ServiceManagement).

## Files

```
Project.swift               Tuist target description (one app + one test target)
Tuist.swift                 Tuist-level config (Xcode 26 compat)
RuEnSync/
├── RuEnSyncApp.swift       @main SwiftUI App, MenuBarExtra UI
├── AppModel.swift          @Observable state; wires LayoutWatcher → HIDLink
├── LayoutWatcher.swift     DistributedNotificationCenter + Carbon TIS API
├── HIDLink.swift           IOHIDManager wrapper, 33-byte report writer
├── ConfigStore.swift       ~/.config/RuEnSync/config.json loader + LayoutResolver
├── LoginItem.swift         SMAppService.mainApp register/unregister
├── Logger.swift            os.Logger subsystem wrappers (Log.layout, Log.hid, …)
└── RuEnSync.entitlements   Empty — IOKit/TIS work outside the sandbox
RuEnSyncTests/              Swift Testing suite (NOT XCTest)
Scripts/
├── notarize.sh             codesign + notarytool + stapler + DMG
└── build-release.sh        End-to-end: clean → build → notarize → DMG
```

## Critical architectural notes (DO NOT FORGET — these will bite)

1. **`@MainActor` propagates to `static` members.** When a class is `@MainActor`,
   its `static let` constants are also main-actor-isolated by default. If they're
   referenced from `nonisolated` contexts (tests, pure helpers), compile fails with
   "main actor-isolated static property X cannot be referenced from a nonisolated
   context". Fix: mark the constant `nonisolated static let`. See `HIDLink.swift`
   `layoutDataType` and `reportSize`.

2. **Swift 6 `deinit` is always `nonisolated`.** Even for an `@MainActor` class. So
   you cannot touch non-Sendable fields (like `IOHIDDevice`, `IOHIDManager`,
   `NSObjectProtocol` observers) from `deinit`. Provide an explicit `stop()` method
   instead and call it from the owner. See `HIDLink.stop()` and `LayoutWatcher.stop()`.

3. **`DistributedNotificationCenter` callback is `@Sendable`.** Even with
   `queue: .main`, Swift 6 will not let you call a `@MainActor` method directly
   from inside the closure. Wrap the call in `MainActor.assumeIsolated { … }` — the
   `.main` queue guarantees we're already on the main thread, so the assumption is
   correct. See `LayoutWatcher.start()`.

4. **HID report is 33 bytes, not 32.** `IOHIDDeviceSetReport` expects the report ID
   as byte 0, followed by the 32-byte QMK `RAW_EPSIZE` payload. So `[0x00, 0xAC,
   idx, 0×30]`. Sending 32 bytes (without the 0x00 prefix) silently fails — IOKit
   rejects, the firmware never sees it. See `HIDLink.send(layoutIndex:)`.

5. **Device selector is `(productId, usagePage, usage)`, NOT vendorId.** The Rust
   `qmk-hid-host` also doesn't use vendorId. We match on the QMK Raw HID convention:
   `usagePage = 0xFF60`, `usage = 0x61`, plus the `productId` from `vial.json`. See
   `HIDLink.start()`.

6. **`TISCopyCurrentKeyboardLayoutInputSource`, not `…KeyboardInputSource`.** The
   former returns the keyboard _layout_ (ABC, Russian, …). The latter can return
   override input sources like the emoji picker, which would confuse us. See
   `LayoutWatcher.readAndDispatch()`.

7. **IOHIDDevice is opened in exclusive mode.** Only one process at a time. If
   `qmk-hid-host` is also running, the second one to open gets
   `kIOReturnExclusiveAccess`. We surface this in the menubar as
   `"Device busy (qmk-hid-host running?)"` via `HIDLink.OfflineReason`; the
   "Reconnect" menu button (`AppModel.reconnectAll()`) lets the user retry
   after killing the conflicting daemon without restarting the app.

8. **`SMAppService.mainApp.register()` is idempotent and safe.** Call on every launch
   — it no-ops if already registered. Status `.requiresApproval` means the user
   hasn't approved in System Settings → Login Items yet; that's fine, we just log
   it. See `LoginItem.registerIfNeeded()`.

## Firmware contract

The keyboard side is in [split_keyboard_layouts/firmware/](https://github.com/alexey1312/split_keyboard_layouts/tree/main/firmware).
The relevant patch is `firmware/crkbd.c.patch`, which wires `raw_hid_receive_kb`
to listen for two packet shapes:

```
[0xAC, idx]              // _LAYOUT  — idx 0 = EN, anything else = RU
[0xB0, 'M','A','C',0x00] // _OS_TYPE — RuEnSync-specific, sent on every connect
```

**`0xAC` MUST stay byte-for-byte compatible with `qmk-hid-host`** so users can
pick either daemon without changing firmware.

**`0xB0` is a RuEnSync extension** sent once on every connect (and on every
manual Reconnect). Payload is the 4-byte ASCII magic from
[`nomis/qmk-hid-identify`](https://github.com/nomis/qmk-hid-identify): `MAC\0`,
`LNX\0`, `WIN\0`, `BSD\0` (we only ever send `MAC\0` since the app is
macOS-only). The firmware uses this to auto-flip into its macOS-Russian variant
without the user touching an on-keyboard toggle after a reflash. Firmware that
doesn't know `0xB0` ignores the unknown data_type — fully backward-compatible.

`0xB0` was chosen because qmk-hid-host's macOS build uses up to `0xAF` (Weather),
and its Linux build uses `0xAD`/`0xAE` for MediaArtist/MediaTitle — `0xB0` is the
first byte safely free across all qmk-hid-host platforms.

If you ever need to extend the protocol further (time tick, caps state, active
app hash), pick a new data_type byte (`0xB1` onwards) and update **both** sides.

## Common tasks

```bash
mise run generate         # regenerate RuEnSync.xcworkspace from Project.swift
mise run build            # debug build
mise run build:release    # release build (universal binary)
mise run test             # Swift Testing suite
mise run format           # swiftformat + dprint (all files)
mise run lint             # swiftlint --strict
mise run run              # tuist run (debug, interactive)
mise run clean            # nuke Derived/build/generated proj
mise run release          # END-TO-END: clean → build → sign → notarize → DMG
                          # requires DEV_ID_APP and NOTARY_PROFILE env vars
```

Debug logs land in the unified log:

```bash
log stream --predicate 'subsystem == "com.alexey1312.ruensync"' --info
```

## Code style

- Match the conventions in existing files. No need to add doc comments to obvious
  things; **do** explain non-obvious _why_ (e.g. the `MainActor.assumeIsolated`
  callsite in `LayoutWatcher`).
- 4-space indent, 120 column max (enforced by `.swiftformat`).
- Tests use the new `Testing` framework (`@Suite`, `@Test`, `#expect`), not XCTest.
- Logger calls go through `Log.<category>` from `Logger.swift`. Always use the
  `os.Logger` API with `privacy:` annotations on interpolated values.

## What NOT to touch without discussion

- The HID packet layout in `HIDLink.send(layoutIndex:)`. Firmware depends on the
  exact byte positions.
- The `kIOHIDPrimaryUsagePageKey / kIOHIDPrimaryUsageKey` filter values. QMK Raw HID
  is hardcoded to `0xFF60 / 0x61`. Changing these means we won't find any keyboards.
- `LSUIElement = true` in Info.plist. Removing it makes the Dock icon appear, which
  defeats the whole "menubar agent" point.

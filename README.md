# RuEnSync

[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

Native macOS menubar app that keeps a QMK keyboard's `cur_lang` in sync with the active
macOS input source. Drop-in replacement for [qmk-hid-host](https://github.com/zzeneg/qmk-hid-host),
written for the [split_keyboard_layouts](https://github.com/alexey1312/split_keyboard_layouts)
Corne firmware — but works with any QMK board that listens for `[0xAC, idx]` on its
Raw HID interface.

> **Status:** working dev build. Universal binary, ad-hoc signed. Notarized release
> coming once Developer ID credentials are wired up.

<!-- screenshot placeholder: drop a PNG of the menubar dropdown here once ready -->
<!-- ![Menubar screenshot](docs/screenshot.png) -->

## Why a native rewrite

[`qmk-hid-host`](https://github.com/zzeneg/qmk-hid-host) is a great cross-platform Rust
daemon, but on macOS it has rough edges:

- Polls the input-source API every **100 ms** instead of subscribing to events.
- Needs `launchctl bootstrap` and a hand-rolled `.plist` to start at login.
- First launch of the downloaded binary trips Gatekeeper.

RuEnSync addresses all three:

- Subscribes to `kTISNotifySelectedKeyboardInputSourceChanged` — **event-driven**, no
  polling, CPU ≈ 0.
- Registers itself via `SMAppService` — appears in *System Settings → General → Login
  Items* as a regular toggle.
- Will ship signed & notarized so first run is a normal app launch.

It speaks the **same wire protocol** as `qmk-hid-host` (`[0x00, 0xAC, idx, 0×30]` —
33-byte HID Output Report). Existing firmware needs no changes.

## Why

The Rust `qmk-hid-host` daemon does its job, but:

- It polls the input-source API every 100 ms.
- It needs a `launchctl bootstrap` LaunchAgent dance to start at login.
- The downloaded binary trips Gatekeeper the first time you run it.

RuEnSync replaces it with a tiny SwiftUI menubar app that:

- Subscribes to `kTISNotifySelectedKeyboardInputSourceChanged` — **event-driven**, no polling.
- Registers itself via `SMAppService` — appears in *System Settings → General → Login Items*
  as a regular toggle.
- Will ship signed & notarized so first run is a normal app launch (no security prompt).

It speaks the same wire protocol (`[0xAC, idx]` at byte offsets 1–2 of a 33-byte HID report)
as `qmk-hid-host`, so **the firmware needs no changes**.

## Install (dev build)

```bash
# 1. clone and build
git clone https://github.com/alexey1312/ruen-sync-mac
cd ruen-sync-mac
mise install              # installs tuist, swiftformat, swiftlint, …
mise run generate         # generates RuEnSync.xcworkspace
mise run build:release    # builds RuEnSync.app

# 2. install into ~/Applications (tuist puts the app under system DerivedData)
APP="$(find ~/Library/Developer/Xcode/DerivedData -name 'RuEnSync.app' -path '*/Release/*' -type d | head -1)"
cp -R "${APP}" ~/Applications/

# 3. first launch — registers as login item automatically
open ~/Applications/RuEnSync.app
```

A signed/notarized DMG release will be available once codesign credentials are wired up.

## Configuration

Lives at `~/.config/RuEnSync/config.json`. Auto-created on first launch with sensible
defaults:

```json
{
  "devices": [{ "productId": "0x0001", "name": "Corne" }],
  "layouts": ["ABC", "Russian"]
}
```

- `productId` — must match your keyboard's `vial.json` / QMK USB ID.
- `layouts` — ordered list of `TISPropertyInputSourceID` suffixes. The index of the active
  layout in this array is the byte sent to the keyboard. Firmware contract: `0 → EN`,
  anything else → RU.
- `usagePage`, `usage` — optional, default to `0xFF60` / `0x61` (QMK Raw HID convention).

Using the Ilya Birman Typography Layout? Change to:

```json
{ "layouts": ["English-IlyaBirmanTypography", "Russian-IlyaBirmanTypography"] }
```

Discover your current input source's suffix:

```bash
defaults read com.apple.HIToolbox AppleSelectedInputSources
# look at "KeyboardLayout Name"
```

## Architecture

```
   ┌──────────────────────────┐
   │  macOS Input Source      │   ← Cmd+Space, Punto, mouse, menubar
   └────────────┬─────────────┘
                │  kTISNotifySelectedKeyboardInputSourceChanged
                ▼
   ┌──────────────────────────┐
   │  LayoutWatcher (Swift)   │   ← reads TISCopyCurrentKeyboardLayoutInputSource()
   └────────────┬─────────────┘
                │
   ┌────────────▼─────────────┐
   │  AppModel (@MainActor)   │   ← menubar state (EN / RU / —)
   └────────────┬─────────────┘
                │
   ┌────────────▼─────────────┐
   │  HIDLink (IOHIDManager)  │   ← matching dict: pid + usage + usagePage
   └────────────┬─────────────┘
                │  IOHIDDeviceSetReport: 33 bytes = [0x00, 0xAC, idx, 0×30]
                ▼
   ┌──────────────────────────┐
   │  crkbd raw_hid_receive_kb │   ← unmodified Vial-QMK firmware
   └──────────────────────────┘
```

Source layout:

| File                              | Role                                                    |
| --------------------------------- | ------------------------------------------------------- |
| `RuEnSync/RuEnSyncApp.swift`      | SwiftUI `@main`, `MenuBarExtra` icon + menu             |
| `RuEnSync/AppModel.swift`         | `@Observable` state, wires Watcher and Link             |
| `RuEnSync/LayoutWatcher.swift`    | Carbon TIS + `DistributedNotificationCenter` subscriber |
| `RuEnSync/HIDLink.swift`          | `IOHIDManager` matching, open/close, `SetReport`        |
| `RuEnSync/ConfigStore.swift`      | Schema + load/seed-default                              |
| `RuEnSync/LoginItem.swift`        | `SMAppService.mainApp` register/unregister              |
| `RuEnSync/RuEnSync.entitlements`  | Empty: IOKit/Carbon work outside the sandbox            |
| `Project.swift`                   | Tuist project description                               |

## Coexistence with qmk-hid-host

`IOHIDDevice` is opened in exclusive mode by both daemons. If you start the Rust
`qmk-hid-host` LaunchAgent **and** RuEnSync at the same time, the second one to open the
device gets `kIOReturnExclusiveAccess` and stays disconnected.

→ **Pick one.** If you used `qmk-hid-host` before, run `cd tools/qmk-hid-host && ./uninstall.sh`
in the firmware repo first.

## Troubleshooting

Logs go to the unified log:

```bash
log stream --predicate 'subsystem == "com.alexey1312.ruensync"' --info
```

Common issues:

- **Menubar shows `—`** — keyboard isn't connected, or `productId` in config doesn't match.
  Check `ioreg -p IOUSB | grep -i corne`.
- **Wrong punctuation in Russian** — your `layouts` array doesn't contain the actual input
  source suffix. Run the `defaults read` command above to inspect.
- **App doesn't start at login** — check *System Settings → General → Login Items* and
  toggle the entry. SMAppService sometimes needs an explicit user confirmation.

## Development

```bash
mise run generate         # regenerate Xcode project from Project.swift
mise run build            # debug build
mise run test             # run unit tests
mise run format           # swiftformat + dprint
mise run lint             # swiftlint --strict
mise run clean            # nuke Derived + generated proj
```

Open the generated `RuEnSync.xcworkspace` in Xcode for IDE work.

## License

MIT — see `LICENSE`.

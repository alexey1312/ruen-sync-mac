<p align="center">
  <img src="RuEnSync/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="RuEnSync app icon" width="160" height="160" />
</p>

<h1 align="center">RuEnSync</h1>

[![CI](https://github.com/alexey1312/ruen-sync-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/alexey1312/ruen-sync-mac/actions/workflows/ci.yml)
[![Release](https://github.com/alexey1312/ruen-sync-mac/actions/workflows/release.yml/badge.svg)](https://github.com/alexey1312/ruen-sync-mac/actions/workflows/release.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

Native macOS menubar app that keeps a QMK keyboard's `cur_lang` in sync with
the active macOS input source. Event-driven (no polling), Login-Item managed,
in-app auto-updates via Sparkle. Drop-in replacement for
[qmk-hid-host](https://github.com/zzeneg/qmk-hid-host).

**Highlights**

- Auto-discovers QMK Raw HID keyboards on first launch — zero config needed
  for the common case.
- Native Settings window (⌘,) for devices, layouts, per-app rules, autostart,
  and debug toggles.
- Per-app layout switching: `Slack → RU`, `Xcode → EN`, etc., configured by
  bundle ID (exact or prefix).
- Auto-yields the keyboard when Vial or QMK Toolbox launches, so flashing
  and reconfiguration "just work" without quitting RuEnSync first.
- Russian-localized UI when macOS is set to Russian; otherwise English.

## Compatible firmware

- [**split_keyboard_layouts**](https://github.com/alexey1312/split_keyboard_layouts) — this
  repo's primary target (Corne). Reacts to the macOS handshake (`0xB0 MAC\0`) and
  auto-flips into its macOS-Russian variant on connect.
- [**ergohaven/vial-qmk**](https://github.com/ergohaven/vial-qmk) — Ergohaven keyboards
  (Planeta V2, K:03 PRO, Imperial44, K:02, K:03 and others using their RuEn mode). The
  `0xAC` layout packet is wire-identical, so RuEnSync drops in without firmware changes;
  the `0xB0` packet is safely ignored — keep using the on-keyboard `RuEn Mac Tg` for the
  Mac toggle.

Also works with any other QMK board that listens for `[0xAC, idx]` on its Raw HID
interface (32-byte report, `usagePage = 0xFF60`, `usage = 0x61`).

## Install

### Homebrew (recommended)

```bash
brew install --cask alexey1312/tap/ruensync
```

### Manual

Grab `RuEnSync.dmg` from the [latest release](https://github.com/alexey1312/ruen-sync-mac/releases/latest),
open it, drag the app to `~/Applications`.

### First launch — one-time Gatekeeper approval

The DMG is **ad-hoc signed** (no paid Apple Developer ID), so macOS blocks the
first launch with _"Apple could not verify RuEnSync is free of malware"_ (or
_"RuEnSync is damaged and can't be opened"_ on Sequoia 15+). This applies to
both `brew --cask` and the manual DMG. One-time fix:

1. Launch `RuEnSync.app` once — let the warning dialog appear, then dismiss it.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the bottom — you'll see `"RuEnSync" was blocked to protect your Mac.`
4. Click **Open Anyway**, confirm with Touch ID / password.

After that the app registers itself as a Login Item via `SMAppService` and every
subsequent launch (including auto-start at login) is normal — no prompts.
Sparkle auto-updates are EdDSA-verified against the key baked into the app, so
they don't re-trigger this dialog.

## Configuration

Most users won't need to touch a config file. On first launch RuEnSync scans
for QMK Raw HID interfaces (UsagePage `0xFF60` / Usage `0x61`) and adds every
match to its config automatically. Open the **Settings** window (⌘, or
_menubar → Settings…_) to:

- **General** — toggle "Launch at login" and master "Auto-switch by app".
- **Devices** — see the auto-discovered list, rename, remove, or rescan.
- **Layouts** — pick from enabled macOS input sources, reorder. The index of
  the active layout in this list is the byte sent to the keyboard
  (`0 → EN`, anything else → RU).
- **App Rules** — map a bundle ID (exact or prefix) to a layout. Activating
  the app programmatically switches the macOS input source, which then
  propagates to the keyboard through the normal path.
- **Debug** — turn on the HID packet ring-buffer + open the Inspector
  window, or export a diagnostics zip for bug reports.

### Manual edits — `~/.config/RuEnSync/config.json`

Settings writes through to this file; you can also edit it directly and the
app will pick up the change without a restart (file watcher). Schema:

```json
{
  "devices": [{ "productId": "0x0001", "name": "Corne" }],
  "layouts": ["ABC", "Russian"],
  "appLayoutRules": [
    { "bundleId": "com.apple.dt.Xcode", "layout": "ABC" },
    { "bundleIdPrefix": "com.jetbrains.", "layout": "ABC" }
  ],
  "appLayoutSwitchingEnabled": true,
  "debug": { "hidInspector": false }
}
```

- `usagePage`, `usage` per-device — optional, default `0xFF60` / `0x61`.
- `appLayoutRules` — `bundleId` (exact) wins over `bundleIdPrefix`; among
  prefixes, the longest match wins. Omit both fields to disable a rule
  without deleting it.
- Layout names are `TISPropertyInputSourceID` suffixes. To see what your
  current input source is called: `defaults read com.apple.HIToolbox
  AppleSelectedInputSources` and look at `"KeyboardLayout Name"`. The Ilya
  Birman Typography Layout is `English-IlyaBirmanTypography` /
  `Russian-IlyaBirmanTypography`.

## Device-busy conflicts

macOS gives exclusive access to an HID device to one process at a time. When
something else holds the lock, RuEnSync surfaces it in the menubar as
**"Device busy (qmk-hid-host running?)"**. Common cases:

- **Vial or QMK Toolbox is open** — RuEnSync detects them by bundle ID
  (`today.vial`, `fm.qmk.toolbox`) and **automatically releases the
  keyboard** while either is running. The menubar shows "Paused — Vial is
  running" with a _Resume anyway_ override; on quit the device is
  re-acquired and the OS-handshake replay happens automatically. No manual
  Reconnect needed.
- **`qmk-hid-host` daemon is running.** The Rust daemon holds the device
  permanently and we don't detect it as a yieldable app. Pick one: uninstall
  its LaunchAgent (or `pkill qmk-hid-host`) and hit **Reconnect** in the
  RuEnSync menu.

## Troubleshooting

Click **Open log…** in the menubar dropdown, or run:

```bash
log stream --predicate 'subsystem == "com.alexey1312.ruensync"' --info
```

The menubar's **Activity** sub-menu also shows the most recent layout
switches, connects, and `_OS_TYPE` handshake results. History persists in
`~/.config/RuEnSync/activity.db`.

For richer bug reports, _Settings → Debug → Export diagnostics…_ bundles
the last hour of logs, the current config, the activity DB, and (when the
inspector is on) the recent HID packet buffer into a single zip in
`~/Downloads`.

Common issues:

- **Menubar pill is outlined / "No device configured"** — auto-discovery
  didn't find anything. Plug the keyboard in, then _Settings → Devices →
  Scan…_. If nothing shows up, confirm the firmware exposes UsagePage
  `0xFF60` / Usage `0x61` (`ioreg -p IOUSB`).
- **Wrong punctuation in Russian** — your `layouts` array doesn't contain
  the active input source's suffix; either add it via _Settings → Layouts_
  or edit config.json directly.
- **App doesn't start at login** — toggle _Launch at login_ in
  _Settings → General_, or check the entry in _System Settings → General →
  Login Items_. `SMAppService` sometimes needs an explicit user
  confirmation after register.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for architecture, build commands, and the
non-obvious gotchas (Swift 6 `@MainActor`/`deinit` interactions, the
HID-packet wire format, Tuist's Info.plist override trap).

Release process and CI secrets are documented in
[`docs/RELEASING.md`](docs/RELEASING.md).

## License

MIT — see [`LICENSE`](LICENSE).

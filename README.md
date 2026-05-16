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

Lives at `~/.config/RuEnSync/config.json`. Auto-created on first launch:

```json
{
  "devices": [{ "productId": "0x0001", "name": "Corne" }],
  "layouts": ["ABC", "Russian"]
}
```

- `devices` — one or more keyboards to sync. `productId` must match your
  `vial.json` / QMK USB ID. Layout and Mac-flag packets are pushed to all of
  them in parallel.
- `layouts` — ordered list of `TISPropertyInputSourceID` suffixes. The index of
  the active layout in this array is the byte sent to the keyboard (`0 → EN`,
  anything else → RU).
- `usagePage`, `usage` — optional, default to `0xFF60` / `0x61`.

Using the Ilya Birman Typography Layout?

```json
{ "layouts": ["English-IlyaBirmanTypography", "Russian-IlyaBirmanTypography"] }
```

Discover your current input source's suffix:

```bash
defaults read com.apple.HIToolbox AppleSelectedInputSources
# look at "KeyboardLayout Name"
```

## Device-busy conflicts

macOS gives exclusive access to an HID device to one process at a time. When
something else holds the lock, RuEnSync surfaces it in the menubar as
**"Device busy (qmk-hid-host running?)"**. Two common culprits:

- **Vial is open.** Vial (or Via) claims the device while its window is
  active for live-configuration / firmware writes. Just close the Vial window
  — RuEnSync's auto-reconnect picks the device back up within a couple of
  seconds. No manual action needed.
- **`qmk-hid-host` daemon is running.** The Rust daemon holds the device
  permanently. Pick one: uninstall its LaunchAgent (or `pkill qmk-hid-host`)
  and hit **Reconnect** in the RuEnSync menu.

## Troubleshooting

Click **Open log…** in the menubar dropdown, or run:

```bash
log stream --predicate 'subsystem == "com.alexey1312.ruensync"' --info
```

The menubar's **Activity** sub-menu also shows the most recent layout
switches, connects, and `_OS_TYPE` handshake results. History persists in
`~/.config/RuEnSync/activity.db`.

Common issues:

- **Menubar shows `—`** — keyboard isn't connected, or `productId` in config
  doesn't match. Check `ioreg -p IOUSB | grep -i corne`.
- **Wrong punctuation in Russian** — your `layouts` array doesn't contain the
  active input source's suffix; run the `defaults read` command above.
- **App doesn't start at login** — toggle the entry in _System Settings →
  General → Login Items_. `SMAppService` sometimes needs an explicit user
  confirmation.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for architecture, build commands, and the
non-obvious gotchas (Swift 6 `@MainActor`/`deinit` interactions, the
HID-packet wire format, Tuist's Info.plist override trap).

Release process and CI secrets are documented in
[`docs/RELEASING.md`](docs/RELEASING.md).

## License

MIT — see [`LICENSE`](LICENSE).

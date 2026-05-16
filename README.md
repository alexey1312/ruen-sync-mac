# RuEnSync

Native macOS menubar app that keeps a [QMK](https://qmk.fm/) keyboard's
`cur_lang` in sync with the active macOS input source. Drop-in replacement
for [qmk-hid-host](https://github.com/zzeneg/qmk-hid-host) — event-driven,
not a 100 ms poll loop.

## Install

```bash
brew install --cask alexey1312/tap/ruensync
```

Or grab `RuEnSync.dmg` from the
[latest release](https://github.com/alexey1312/ruen-sync-mac/releases/latest).

## In-app auto-updates

This site also serves the Sparkle update feed at
[`/appcast.xml`](./appcast.xml). The app checks it once a day and offers any
newer version through the menubar's "Check for Updates…" item. Every DMG is
EdDSA-signed; older installs verify the signature before installing.

## Source

Code, issues, and discussions live in the
[`alexey1312/ruen-sync-mac`](https://github.com/alexey1312/ruen-sync-mac)
repository.

---

<sub>This page is built from the `gh-pages` branch via GitHub Pages.</sub>

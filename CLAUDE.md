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
- **Swift 6** with strict concurrency. macOS 14 (Sonoma) minimum — bound by
  `@Observable` / Observation framework. Lowering further would require
  switching to `ObservableObject`/`@Published`.
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
├── HIDLink.swift           IOHIDManager wrapper, 32-byte report writer
├── ConfigStore.swift       ~/.config/RuEnSync/config.json loader + LayoutResolver
├── LoginItem.swift         SMAppService.mainApp register/unregister
├── Logger.swift            os.Logger subsystem wrappers (Log.layout, Log.hid, …)
├── DesignSystem/           Shared UI primitives — palette, capsules, badges
└── RuEnSync.entitlements   Empty — IOKit/TIS work outside the sandbox
RuEnSyncTests/              Swift Testing suite (NOT XCTest)
Scripts/
├── notarize.sh             codesign + notarytool + stapler + DMG
└── build-release.sh        End-to-end: clean → build → notarize → DMG
```

## Design system

UI primitives shared across screens live in `RuEnSync/DesignSystem/`. **Do
not hand-roll capsules, status dots, card backgrounds, or tab headers
inline** — use the DS so the EN/RU colour story, capsule rhythm, and
rounded-corner conventions stay consistent.

| Primitive                               | File                  | When to use                                           |
| --------------------------------------- | --------------------- | ----------------------------------------------------- |
| `Color.dsAccentEN/RU`                   | `DSColor.swift`       | Layout-index-derived tints; mirrors the menubar pill  |
| `Color.dsAccentENBadge/RUBadge`         | `DSColor.swift`       | Tinted capsule fills (slightly darker than pill hue)  |
| `Color.dsOk/dsWarn/dsBad/dsUnknown`     | `DSColor.swift`       | Semantic status colours                               |
| `Color.dsAccent(forLayoutIndex:)`       | `DSColor.swift`       | `nil`-safe lookup used by `MenuLabel` and friends     |
| `.dsCapsule(tone:)`                     | `DSCapsule.swift`     | Inline pill backgrounds — see `DSCapsuleTone` cases   |
| `StatusDot(tint:)`                      | `StatusDot.swift`     | Device-connection state in lists / rows               |
| `IndexBadge(index:)`                    | `IndexBadge.swift`    | Firmware layout-index column in row leading slot      |
| `DSCard { }` modifier                   | `DSCard.swift`        | Empty-state / banner / example containers with border |
| `DSTabHeader(title:subtitle:trailing:)` | `DSTabHeader.swift`   | Settings tab masthead (title + subtitle + action)     |
| `DSErrorBanner(text:onDismiss:)`        | `DSErrorBanner.swift` | Recoverable error surfaces above content              |

**Palette is hand-tuned, not semantic.** The exact RGB values in
`DSColor` are load-bearing: the menubar `MenuLabel` pill, the
`IndexBadge` in Settings → Layouts, the `StatusDot` on Device rows, and
the LAYOUT tag in HID Inspector all draw from the same constants so EN
intuition (blue) ↔ RU intuition (coral) ↔ healthy intuition (green)
carries unchanged between surfaces. When extending: add a new
`dsXxx` constant rather than introducing a raw `Color(red:green:blue:)`
literal at a call site. A naming collision with the system palette
(`Color.green` etc.) is deliberate — it forces grep-ability.

`SwiftUI.Color` extensions on `DSColor.swift` are NOT `nonisolated` —
they don't need to be, `Color` is `Sendable` and the static lets are
plain value-typed initialisers. If you ever wrap them in a
`@MainActor` type (don't), see note 1 about static-isolation propagation.

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

4. **HID report is exactly 32 bytes (`RAW_EPSIZE`), starting with the data-type byte.**
   `IOHIDDeviceSetReport(reportID = 0, …)` on macOS sends the buffer **as-is** —
   it does NOT strip a leading report-ID byte the way hidapi does. So the buffer
   must be `[0xAC, idx, 0×30]` (32 bytes), not `[0x00, 0xAC, idx, 0×30]` (33).
   Sending the 33-byte hidapi-style form is the subtle bug that silently breaks
   sync: the device receives `data[0] = 0x00`, fails the `data[0] == 0xAC`
   check, and drops the packet. Apple docs on `IOHIDDeviceSetReport`: "For
   output reports, the bytes are sent as-is to the device." hidapi's macOS
   backend handles the discrepancy by stripping a leading `0x00` before
   calling `IOHIDDeviceSetReport`; we call IOKit directly, so we must build
   the wire-correct buffer ourselves. See `HIDLink.buildReport(layoutIndex:)`
   and `HIDPacketTests.swift`.

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

9. **Tuist's `.extendingDefault` Info.plist silently overrides version build
   settings.** It bakes literal `CFBundleShortVersionString="1.0"` and
   `CFBundleVersion="1"` into the plist, which Apple's build pipeline considers
   authoritative over `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` build
   settings. v1.1.0 shipped reporting version `1.0` because of this — Sparkle's
   appcast then advertised `1.0` and existing installs couldn't see future
   updates. Pin the plist values to `"$(MARKETING_VERSION)"` /
   `"$(CURRENT_PROJECT_VERSION)"` in the `infoPlist:` dict so Xcode resolves
   them at compile time. See `Project.swift` Info.plist block.

10. **`NSWindow.Level.floating` requires an NSViewRepresentable bridge.**
    SwiftUI's `Window` scene doesn't expose `level` declaratively until macOS
    15. Use a tiny `WindowConfigurator: NSViewRepresentable` in `.background(…)`
    that grabs `view.window` from inside an async hop. See `HIDInspectorView`.

11. **`String(localized:)` for non-SwiftUI strings.** SwiftUI's `Text`/`Button`/
    `Toggle` auto-extract into `RuEnSync/Resources/Localizable.xcstrings`. For
    code-formed strings (`OfflineReason.menuLabel`, `ActivityKind.headline`,
    `DeviceStatus.summary`) wrap in `String(localized: "…")` so Xcode picks
    them up. Russian translations use positional placeholders (`%1$@`, `%2$@`)
    where word order differs from English.

12. **First-run device discovery is gated by UserDefaults flag**
    `ruensync.autoDiscoveryRan`. Without it, deleting the last device in
    Settings would resurrect it on the next launch. The flag is set ONLY
    after a successful `ConfigStore.save` — a save failure keeps the flag
    clear so the next launch retries. The flag is one-time and has no
    "reset" UI; to manually pick up newly-plugged keyboards, use Settings
    → Devices → **Scan…**, which opens a picker showing all visible QMK
    Raw HID devices and adds them one at a time.

13. **`ConfigStore.load()` returns a `LoadResult` enum**
    (`.loaded`/`.missing`/`.corrupt`). Never use the older
    `loadOrSeedDefaults` path for new code: it conflates "first run" with
    "user's config is broken", and the latter must NOT trigger
    auto-discovery (which would then overwrite the recoverable bad file
    with a discovered-devices shell). `AppModel(allowAutoDiscoverySeed:)`
    is the gate; pass `false` when the load was `.corrupt`. The
    file-watcher classifies events the same way and refuses to apply a
    `.corrupt` decode — it surfaces `lastSettingsError` and records
    `ActivityKind.configInvalid` instead of replacing the live config.

14. **Self-write suppression in `ConfigStore.watch` uses a SHA stamp.**
    The previous 500 ms time-window heuristic both let burst fsevents
    leak through (logging duplicate `configReloaded`) and could swallow
    fast external edits. `lastWrittenSHA` is stamped on every `save` /
    `writeDefault` / clean `load`; the watcher compares the SHA of the
    on-disk bytes against that stamp and only fires `onChange` for
    foreign writes.

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
manual Reconnect). Payload is the 4-byte ASCII OS magic from
[`nomis/qmk-hid-identify`](https://github.com/nomis/qmk-hid-identify): `MAC\0`,
`LNX\0`, `WIN\0`, `BSD\0` (we only ever send `MAC\0` since the app is
macOS-only). The firmware uses this to auto-flip into its macOS-Russian variant
without the user touching an on-keyboard toggle after a reflash. Firmware that
doesn't know `0xB0` ignores the unknown data_type — fully backward-compatible.

**Wire-compat caveat:** we borrow only the 4-byte OS magic from
`qmk-hid-identify`. nomis's actual wire format prefixes packets with
`[0x00, 0x01]` instead of a data_type byte, so a firmware running nomis's
unmodified `raw_hid_receive_identify` dispatcher will NOT pick up our packets.
Compatibility is intentional at the magic level only.

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

`mise run build` pipes through xcsift, which can show `status: success` while
tuist's incremental cache silently skipped a file with a real compile error.
If a behaviour change isn't showing up in the running app, `touch
RuEnSync/<EditedFile>.swift && tuist build RuEnSync 2>&1 | tail -30` forces a
real recompile and surfaces the actual diagnostics.

### Live testing & debugging

- Shell has an `alias log=…` (rtk wrapper). Use `/usr/bin/log` explicitly for
  streams: `/usr/bin/log stream --predicate 'subsystem == "com.alexey1312.ruensync"' --level info --style compact`.
- macOS doesn't persist `.info`-level entries by default — `log show --info`
  after-the-fact misses them. Either start `log stream --level info` BEFORE
  the run, or rely on `.error` for post-mortems.
- `NSWorkspace.didTerminateApplicationNotification` arrives ~30 s after a
  SIGTERM (`kill <pid>`) for GUI apps. For deterministic testing of
  ConflictWatcher resume use `osascript -e 'tell application "Vial" to quit'`.
- LaunchServices caches `.app` bundles by path. After `tuist build`, verify the
  binary actually changed: `stat -f '%m %N' …/Debug/RuEnSync.app/Contents/MacOS/RuEnSync`
  vs `date +%s`. If old, `touch` a swift source and rebuild.
- `NSWorkspace.shared.notificationCenter` ≠ `NotificationCenter.default` —
  subscribing to the latter for workspace events is a silent no-op.

### Process + Pipe gotcha

`Process` + `Pipe()` deadlocks once the child writes more than the
pipe buffer (~64 KB on macOS) if you `waitUntilExit()` before reading
the pipes — child blocks on `write()`, parent blocks on wait, nobody
makes progress. `log show --info --last 1h` routinely crosses that
threshold. Drain stdout AND stderr concurrently before waiting —
`Diagnostics.runShell` is the canonical pattern: `async throws`
function that fires two `Task.detached { readDataToEndOfFile() }`
reads, awaits them both, then calls `waitUntilExit()` purely to read
`terminationStatus`.

### Launching the debug build

`tuist run RuEnSync` fails with _"no suitable device for macOS"_ on Tuist 4.56
— it picks an iOS simulator and ignores `.mac` destinations. After
`mise run build`, launch the `.app` directly:

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'RuEnSync.app' -path '*/Debug/*' -type d | xargs -I {} stat -f '%m %N' {} | sort -rn | head -1 | awk '{print $2}')"
```

Or open the generated workspace in Xcode and ⌘R.

## Code style

- Match the conventions in existing files. No need to add doc comments to obvious
  things; **do** explain non-obvious _why_ (e.g. the `MainActor.assumeIsolated`
  callsite in `LayoutWatcher`).
- 4-space indent, 120 column max (enforced by `.swiftformat`).
- Tests use the new `Testing` framework (`@Suite`, `@Test`, `#expect`), not XCTest.
- Logger calls go through `Log.<category>` from `Logger.swift`. Always use the
  `os.Logger` API with `privacy:` annotations on interpolated values.
- SwiftUI row views that need a `guard let` against an array-index lookup
  (e.g. `model.config.devices[safe: index]`) should use `@ViewBuilder var body`
  - `if let`, NOT `AnyView(EmptyView()) / AnyView(HStack{…})`. The `AnyView`
    form erases types and disables SwiftUI's view-update fast path; we fixed
    three copies in `SettingsAppRulesTab` / `SettingsDevicesTab` /
    `SettingsLayoutsTab` during the feat/auto-yield review pass.

### Tests and persistent state

- `ActivityStore()` (no-args init) opens the **real** `~/.config/RuEnSync/activity.db`.
  Tests that touch `model.activity` and assert on `entries.count` or
  `count + 1` will pass in isolation and then start failing once the
  on-disk log accumulates ≥ capacity rows from earlier runs (capacity
  caps the in-memory mirror at 100). Prefer asserting on
  `entries.first?.kind` / `entries.first?.id` — they're stable under
  any accumulated history. For end-to-end isolation, use the test-only
  `ActivityStore(database:)` init with `try ActivityDatabase(path: ":memory:")`.
- `AppModel` test models can be built with `allowAutoDiscoverySeed: false`
  to skip the IOKit-touching first-run discovery path.

### Format / lint quirks

- `mise run format:swift` skips `Project.swift` — it only walks `RuEnSync/` and
  `RuEnSyncTests/`. To format everything (including `Project.swift`), run
  `mise run format` (which goes through `hk fix --all`).
- SwiftLint runs in **strict** mode with `cyclomatic_complexity` capped at 10. A
  switch over the 7-case `ActivityKind` with `guard let` trips it. Wrap legitimate
  parser dispatch in a `// swiftlint:disable cyclomatic_complexity` … `// swiftlint:enable
  cyclomatic_complexity` **block**. A `:next`-style comment between `///` doc and
  declaration breaks `orphaned_doc_comment` — don't do that.
- SwiftLint `file_length` capped at 400. When `AppModel.swift` grows past it,
  move logic into `AppModel+Coordination.swift` (extension); stored properties
  stay in core, methods + computed properties move out. Make `private` →
  internal for members the extension touches.
- SwiftLint `nesting` capped at 1. A sum type inside a struct inside an
  outer type (`Config.AppLayoutRule.Match`) violates this; suppress with
  `// swiftlint:disable:next nesting` on the inner declaration when the
  type is meaningless outside its enclosing scope (promoting it to
  module scope just leaks namespace).
- `mise run format` (hk fix) will split long `Text("…")` / `String(…)`
  literals across multiple lines, which silently invalidates any
  `// swiftlint:disable:previous line_length` annotation that used to
  apply (the "previous" line is now the closing paren, not the long
  string). Prefer `"first half " + "second half"` concatenation over
  the disable-comment trick for strings the formatter is likely to wrap.
- swiftformat strips `self.` from interpolations even inside Logger's
  `@autoclosure` context, breaking compile with _"reference to property X in
  closure requires explicit use of 'self'"_. Fix: bind to a local let first —
  `if let yielded = yieldedTo { Log.app.info("…\(yielded, privacy: .public)") }`.
- SourceKit frequently shows phantom _"No such module 'Sparkle' / 'SQLite' /
  'ProjectDescription'"_ errors right after edits or package resolves. They lag
  behind project regeneration. The real source of truth is `mise run build` /
  `mise run test`; ignore the IDE's red squigglies if those are green.

## What NOT to touch without discussion

- The HID packet layout in `HIDLink.send(layoutIndex:)`. Firmware depends on the
  exact byte positions.
- The `kIOHIDPrimaryUsagePageKey / kIOHIDPrimaryUsageKey` filter values. QMK Raw HID
  is hardcoded to `0xFF60 / 0x61`. Changing these means we won't find any keyboards.
- `LSUIElement = true` in Info.plist. Removing it makes the Dock icon appear, which
  defeats the whole "menubar agent" point.

## Fetching PR review comments

`gh pr view N --comments` shows only top-level comments — `gemini-code-assist`
(and any human inline reviewer) writes per-line review comments that live on a
different endpoint. Use:

```bash
gh api repos/alexey1312/ruen-sync-mac/pulls/<N>/comments \
  --jq '.[] | {path, line, body, user: .user.login}'
```

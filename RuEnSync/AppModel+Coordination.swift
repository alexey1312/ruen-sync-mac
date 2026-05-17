import Foundation

// MARK: - AppModel+Coordination

/// Extensions hosting the watcher-coordination logic that grew too large for
/// the core AppModel file: conflict (Vial / QMK Toolbox) handling, per-app
/// layout switching, and dynamic config reload. Stored properties stay in
/// `AppModel.swift` — extensions can only add methods and computed members.
extension AppModel {
    // MARK: Force resume + conflict handling

    /// User-initiated override: leave yielded state even if the conflicting
    /// app is still running, and try to retake the device. Wired to the
    /// "Resume anyway" menu item that appears only when yielded.
    func forceResume() {
        guard yieldedTo != nil else { return }
        Log.app.info("force-resume requested by user")
        handleConflictCleared()
    }

    func handleConflictAppeared(appName: String) {
        // Already yielded to something — record the *new* app but keep the
        // current `yieldedTo` label since we don't track multiple concurrent
        // conflicts in the UI (the activity log carries the full sequence).
        if yieldedTo != nil {
            activity.record(.yieldedToApp(name: appName))
            return
        }

        yieldedTo = appName
        cancelReconnectTask()
        for link in hidLinks {
            link.stop()
        }
        hidLinks = []
        deviceStatuses = []
        Log.app.info("yielded HID device to \(appName, privacy: .public)")
        activity.record(.yieldedToApp(name: appName))
    }

    func handleConflictCleared() {
        guard let previousApp = yieldedTo else { return }
        yieldedTo = nil
        Log.app.info("resuming after \(previousApp, privacy: .public)")
        activity.record(.resumedAfterApp(name: previousApp))
        buildAndStartLinks()
    }

    // MARK: Per-app layout switching

    /// Looks up a rule for the activated app and, if found, requests a
    /// programmatic input-source switch. The actual `HIDLink.send` happens
    /// through the existing `LayoutWatcher → onLayoutChanged → hidLinks`
    /// path — we don't duplicate the transmit logic here.
    func handleAppActivated(bundleId: String) {
        guard config.effectiveAppLayoutSwitchingEnabled else { return }
        guard let rules = config.appLayoutRules, !rules.isEmpty else { return }
        guard let rule = AppLayoutRuleMatching.match(rules: rules, bundleId: bundleId) else { return }

        // Skip if the rule's target layout is already active — avoids a TIS
        // call (and the corresponding HID write) on every app switch when
        // the layout already matches.
        if let lastIndex = layoutWatcher.lastIndex,
           lastIndex < config.layouts.count,
           config.layouts[Int(lastIndex)] == rule.layout
        {
            return
        }

        switch layoutWatcher.selectInputSource(layoutName: rule.layout) {
        case .success:
            activity.record(.appLayoutOverride(bundleId: bundleId, layoutName: rule.layout))
        case let .failure(reason):
            activity.record(.appLayoutOverrideFailed(
                bundleId: bundleId,
                layoutName: rule.layout,
                reason: reason.activityLabel
            ))
        }
    }

    /// True iff the config defines at least one per-app rule. The menubar
    /// uses this to decide whether to render the "Auto-switch by app"
    /// toggle at all — no rules means the toggle would be a no-op.
    var hasAppLayoutRules: Bool {
        !(config.appLayoutRules?.isEmpty ?? true)
    }

    /// Read-only view of the master per-app switching flag, with the implicit
    /// default applied. Writes must go through `editConfig` so they persist
    /// — the menubar Toggle and the Settings checkbox both rely on that.
    var appLayoutSwitchingEnabled: Bool {
        config.effectiveAppLayoutSwitchingEnabled
    }

    // MARK: Dynamic config reload

    /// Replaces the live config with a freshly-loaded version from disk and
    /// rebuilds whatever depends on it. We diff conservatively: only
    /// `devices`/`layouts` changes warrant a full HIDLink rebuild (the
    /// expensive part). `appLayoutRules` are read on every activation, so
    /// updating them is just a property assignment.
    ///
    /// No-op when `newConfig == config` (which happens when the file-watcher
    /// fires for a save that produced the identical bytes — e.g. SHA-mismatch
    /// timing window) — preserves the "silent no-op" invariant: no log
    /// noise, no activity-log entry.
    func applyNewConfig(_ newConfig: Config) {
        guard newConfig != config else { return }
        let devicesChanged = newConfig.devices != config.devices
        let layoutsChanged = newConfig.layouts != config.layouts
        config = newConfig
        Log.config.info("config reloaded from disk")
        activity.record(.configReloaded)
        if devicesChanged || layoutsChanged, yieldedTo == nil {
            // reconnectAll is a no-op while yielded, so this is also safe
            // mid-Vial — links rebuild on resume against the new config.
            reconnectAll()
        } else {
            // No rebuild, but debug-flag changes still need to take effect.
            refreshInspectionFlag()
        }
    }

    /// Routes a ConfigStore watcher event into the right path. Loaded → apply.
    /// Corrupt → surface in `lastSettingsError` and the activity log, but
    /// keep the previously-applied config in force. Missing → ignored: the
    /// most likely cause is an in-progress atomic rename; if the file is
    /// permanently gone we keep running on the last known config until the
    /// user puts it back or reopens the app.
    func handleConfigEvent(_ result: ConfigStore.LoadResult) {
        switch result {
        case let .loaded(newConfig):
            applyNewConfig(newConfig)
        case .missing:
            Log.config.warning("config watch: file briefly missing — keeping previous")
        case let .corrupt(error):
            Log.config
                .error(
                    "config watch: refusing to apply invalid config — \(error.localizedDescription, privacy: .public)"
                )
            lastSettingsError = String(
                localized: "Config file is invalid — keeping previous state. Fix ~/.config/RuEnSync/config.json or revert your edit."
            )
            activity.record(.configInvalid)
        }
    }

    // MARK: Config edits from Settings UI

    /// Mutates the in-memory config, persists it to disk, and re-applies
    /// the changes immediately. The persisted write stamps a SHA so the
    /// file-watcher knows to skip its own resulting fsevent — see
    /// `ConfigStore.lastWrittenSHA`.
    func editConfig(_ transform: (inout Config) -> Void) {
        var updated = config
        transform(&updated)
        guard updated != config else { return }
        do {
            try ConfigStore.save(updated)
        } catch {
            Log.config.error("save failed: \(error.localizedDescription, privacy: .public)")
            lastSettingsError = String(localized: "Couldn't save settings: \(error.localizedDescription)")
            return
        }
        // Clear any prior error since the latest save succeeded.
        if lastSettingsError != nil { lastSettingsError = nil }
        applyNewConfig(updated)
    }

    // MARK: Auto-discovery

    /// Synchronously polls IOKit for QMK Raw HID interfaces and adds every
    /// discovered device to the config. Returns `true` if devices were found
    /// AND successfully persisted (in which case the caller may set the
    /// "discovery ran" flag); `false` on no-device or on save failure (in
    /// which case the flag must stay clear so the next launch retries).
    @discardableResult
    func autoDiscoverDevices() -> Bool {
        let found = DeviceDiscovery.scan()
        guard !found.isEmpty else {
            Log.app.info("auto-discovery: no QMK Raw HID devices visible at launch")
            return false
        }
        Log.app.info("auto-discovery: seeded \(found.count, privacy: .public) device(s)")
        config.devices = found.map { discovered in
            Config.Device(
                name: discovered.displayName,
                productId: discovered.productIdHex,
                usagePage: nil,
                usage: nil
            )
        }
        // Persist so subsequent launches don't re-scan, and so a manual
        // edit in Settings has something to start from.
        do {
            try ConfigStore.save(config)
            return true
        } catch {
            Log.config.error("auto-discovery save failed: \(error.localizedDescription, privacy: .public)")
            // Don't surface as a Settings error: this fires very early in
            // launch before the user can do anything about it. The empty
            // devices state already signals "needs attention" in the UI.
            return false
        }
    }
}

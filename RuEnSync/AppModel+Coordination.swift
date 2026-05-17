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
    func handleAppActivated(bundleId: String?) {
        guard appLayoutSwitchingEnabled else { return }
        guard let bundleId else { return }
        guard let rules = config.appLayoutRules, !rules.isEmpty else { return }
        guard let rule = AppLayoutRuleMatching.match(rules: rules, bundleId: bundleId) else { return }

        // Skip if the rule's target layout is already active — avoids a TIS
        // call (and the corresponding HID write) on every app switch when
        // the layout already matches.
        if let lastIndex = layoutWatcher.lastIndex,
           lastIndex < config.layouts.count,
           config.layouts[Int(lastIndex)] == rule.layout {
            return
        }

        let ok = layoutWatcher.selectInputSource(layoutName: rule.layout)
        if ok {
            activity.record(.appLayoutOverride(bundleId: bundleId, layoutName: rule.layout))
        }
    }

    /// True iff the config defines at least one per-app rule. The menubar
    /// uses this to decide whether to render the "Auto-switch by app"
    /// toggle at all — no rules means the toggle would be a no-op.
    var hasAppLayoutRules: Bool {
        !(config.appLayoutRules?.isEmpty ?? true)
    }

    /// Two-way binding target for the menubar toggle. Reads the effective
    /// state (defaults to `true` when unset, matching `handleAppActivated`),
    /// and on write updates the in-memory config — the file is NOT touched
    /// because the toggle is meant as a quick override, not a destructive
    /// rewrite of the user's config.json.
    var appLayoutSwitchingEnabled: Bool {
        get { config.appLayoutSwitchingEnabled ?? true }
        set { config.appLayoutSwitchingEnabled = newValue }
    }

    // MARK: Dynamic config reload

    /// Replaces the live config with a freshly-loaded version from disk and
    /// rebuilds whatever depends on it. We diff conservatively: only
    /// `devices`/`layouts` changes warrant a full HIDLink rebuild (the
    /// expensive part). `appLayoutRules` are read on every activation, so
    /// updating them is just a property assignment.
    func applyNewConfig(_ newConfig: Config) {
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

    // MARK: Config edits from Settings UI

    /// Mutates the in-memory config, persists it to disk, and re-applies
    /// the changes immediately. The persisted write sets a self-write
    /// marker so the file-watcher doesn't double-apply — see
    /// `ConfigStore.selfWritingMarker`.
    func editConfig(_ transform: (inout Config) -> Void) {
        var updated = config
        transform(&updated)
        guard updated != config else { return }
        do {
            try ConfigStore.save(updated)
        } catch {
            Log.config.error("save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        applyNewConfig(updated)
    }
}

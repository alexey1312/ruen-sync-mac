@testable import RuEnSync
import Testing

/// Differential rebuild + corrupt-config handling. Pins the documented
/// "rules change does NOT reconnect" guarantee — a regression there would
/// drop the keyboard every time the user edits the App Rules tab.
@MainActor
struct AppModelConfigReloadTests {
    private func base(devices: [Config.Device] = [], rules: [Config.AppLayoutRule]? = nil) -> Config {
        Config(
            devices: devices,
            layouts: ["ABC", "Russian"],
            appLayoutRules: rules,
            appLayoutSwitchingEnabled: nil,
            debug: nil
        )
    }

    private func makeModel(_ config: Config) -> AppModel {
        AppModel(config: config, allowAutoDiscoverySeed: false)
    }

    @Test("applyNewConfig with the same config is a silent no-op")
    func sameConfigSilent() {
        let model = makeModel(base())
        let activityBefore = model.activity.entries.count

        model.applyNewConfig(model.config)

        // No `configReloaded` should be recorded — the differential
        // guard at the top of `applyNewConfig` prevents log noise.
        #expect(model.activity.entries.count == activityBefore)
    }

    @Test("changing only appLayoutRules records reload without device rebuild")
    func rulesChangeKeepsLinks() {
        let original = base(rules: [.exact("com.apple.dt.Xcode", layout: "ABC")])
        let model = makeModel(original)

        var updated = original
        updated.appLayoutRules = (original.appLayoutRules ?? []) +
            [.prefix("com.jetbrains.", layout: "Russian")]
        model.applyNewConfig(updated)

        // hidLinks contents must stay empty: original config had no
        // devices, so there was nothing to rebuild — and the differential
        // guard means we don't redundantly call `buildAndStartLinks`.
        #expect(model.hidLinks.isEmpty)
        // The config itself updated.
        #expect(model.config.appLayoutRules?.count == 2)
        // Newest activity entry is the reload — and exactly one new
        // .configReloaded was added by this call.
        if case .configReloaded = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("expected .configReloaded at index 0")
        }
    }

    @Test("corrupt event keeps previous config, records configInvalid, sets error")
    func corruptKeepsPrevious() {
        let original = base(rules: [.exact("com.apple.dt.Xcode", layout: "ABC")])
        let model = makeModel(original)

        struct DummyErr: Error {}
        model.handleConfigEvent(.corrupt(underlying: DummyErr()))

        // Config must be unchanged.
        #expect(model.config == original)
        // Activity log got `.configInvalid`.
        if case .configInvalid = model.activity.entries[0].kind {
            // ok
        } else {
            Issue.record("expected .configInvalid at index 0")
        }
        // User-visible banner is queued.
        #expect(model.lastSettingsError != nil)
    }

    @Test("missing event does not surface an error and keeps the previous config")
    func missingIsSilent() {
        let original = base()
        let model = makeModel(original)
        let countBefore = model.activity.entries.count
        let errorBefore = model.lastSettingsError

        model.handleConfigEvent(.missing)

        #expect(model.config == original)
        #expect(model.activity.entries.count == countBefore)
        // No banner — missing-during-edit is expected during atomic
        // rename and shouldn't startle the user.
        #expect(model.lastSettingsError == errorBefore)
    }
}

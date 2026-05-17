import AppKit
import SwiftUI

// MARK: - AppRulesTab

struct SettingsAppRulesTab: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSTabHeader(
                title: "App layout rules",
                subtitle: "Exact match wins over prefix. Among prefixes, the longest match wins."
            ) {
                Button {
                    addRule()
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            let rules = model.config.appLayoutRules ?? []
            if rules.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(rules.indices, id: \.self) { idx in
                        AppRuleRow(model: model, index: idx)
                    }
                }
                .listStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func addRule() {
        model.editConfig {
            var list = $0.appLayoutRules ?? []
            let firstLayout = $0.layouts.first ?? "ABC"
            list.append(.exact("com.example.app", layout: firstLayout))
            $0.appLayoutRules = list
        }
    }

    /// Empty state with concrete example. Users land here without context
    /// for what "exact / prefix bundle id" means — the example row makes the
    /// idea tangible at a glance. Visually it sits as an inert preview card,
    /// not a clickable affordance — the real Add button lives in the header.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.badge")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No rules yet")
                .font(.headline)
            Text("Map a bundle ID to a layout — when the app activates, RuEnSync flips macOS to that layout.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 4) {
                Text("Example")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                exampleCard
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var exampleCard: some View {
        HStack(spacing: 8) {
            Text("Exact")
                .font(.caption.weight(.medium))
                .dsCapsule(tone: .muted, size: .comfortable)
            Text("com.apple.Terminal")
                .font(.body.monospaced())
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text("ABC")
                .font(.body.monospaced())
                .dsCapsule(tone: .accent, size: .comfortable)
        }
        .padding(10)
        .dsCard()
    }
}

private enum MatchKind: String, CaseIterable, Identifiable {
    case exact, prefix
    var id: String {
        rawValue
    }
}

/// Editable row for one `appLayoutRule`. Uses a local `@State` draft for
/// the bundle ID so we only persist on blur / Enter — saving on every
/// keystroke would log a `configReloaded` activity entry and re-emit
/// fsevents for each character. Layout dropdown and match-kind picker
/// commit immediately, since those are single-tap operations.
private struct AppRuleRow: View {
    @Bindable var model: AppModel
    let index: Int

    @State private var bundleDraft: String = ""
    @State private var matchKind: MatchKind = .exact
    /// Cached LaunchServices lookup result. Refreshed only on commit /
    /// row attach — NOT on every keystroke in the bundle TextField,
    /// which would re-run `urlForApplication(withBundleIdentifier:)` +
    /// `icon(forFile:)` per character and introduce typing latency on
    /// slower Macs (and burn LaunchServices DB hits on every paste).
    @State private var resolvedIconURL: URL?
    @FocusState private var bundleFocused: Bool

    var body: some View {
        if let rule = (model.config.appLayoutRules ?? [])[safe: index] {
            HStack(spacing: 8) {
                appIconView

                Picker("", selection: $matchKind) {
                    Text("Exact").tag(MatchKind.exact)
                    Text("Prefix").tag(MatchKind.prefix)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
                .onChange(of: matchKind) { _, _ in commitBundle() }

                TextField("com.app.bundle", text: $bundleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($bundleFocused)
                    .onSubmit { commitBundle() }
                    .onChange(of: bundleFocused) { _, isFocused in
                        if !isFocused { commitBundle() }
                    }

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { rule.layout },
                    set: { newLayout in
                        model.editConfig { cfg in
                            var list = cfg.appLayoutRules ?? []
                            guard index < list.count else { return }
                            list[index].layout = newLayout
                            cfg.appLayoutRules = list
                        }
                    }
                )) {
                    ForEach(model.config.layouts, id: \.self) { layout in
                        Text(layout).tag(layout)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                Button(role: .destructive) {
                    model.editConfig { cfg in
                        var list = cfg.appLayoutRules ?? []
                        guard index < list.count else { return }
                        list.remove(at: index)
                        cfg.appLayoutRules = list.isEmpty ? nil : list
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
            }
            .padding(.vertical, 4)
            .onAppear { syncDraftFromRule(rule) }
            .onChange(of: rule) { _, newRule in syncDraftFromRule(newRule) }
        }
    }

    /// Renders the cached system app icon for the current bundle id. The
    /// cache (`resolvedIconURL`) is refreshed on commit + row attach via
    /// `refreshResolvedIcon()`, so changing the TextField text doesn't
    /// trigger a LaunchServices lookup per keystroke. Fallback is a
    /// neutral `app.dashed` glyph that keeps every row's 22pt leading
    /// slot occupied so columns stay aligned.
    @ViewBuilder
    private var appIconView: some View {
        if let url = resolvedIconURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .help(matchKind == .exact
                    ? String(localized: "No app installed with this bundle id")
                    : String(localized: "Icon preview only available for exact matches"))
        }
    }

    /// Re-resolves the icon for the currently-displayed bundle id. Only
    /// called on commit / row-attach — not on every keystroke.
    private func refreshResolvedIcon() {
        guard matchKind == .exact else {
            resolvedIconURL = nil
            return
        }
        let trimmed = bundleDraft.trimmingCharacters(in: .whitespaces)
        resolvedIconURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
    }

    private func syncDraftFromRule(_ rule: Config.AppLayoutRule) {
        switch rule.match {
        case let .exact(id):
            bundleDraft = id
            matchKind = .exact
        case let .prefix(p):
            bundleDraft = p
            matchKind = .prefix
        }
        refreshResolvedIcon()
    }

    /// Persist the draft. Empty / whitespace-only input is refused because
    /// the rule type can't represent "nothing to match" — we'd rather keep
    /// the previous value than create an unfireable rule that the matcher
    /// would silently skip. The user explicitly removes a rule with the "−"
    /// button.
    private func commitBundle() {
        let trimmed = bundleDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Restore the displayed draft to whatever's currently persisted,
            // so the empty TextField doesn't silently linger.
            if let rule = (model.config.appLayoutRules ?? [])[safe: index] {
                syncDraftFromRule(rule)
            }
            return
        }
        model.editConfig { cfg in
            var list = cfg.appLayoutRules ?? []
            guard index < list.count else { return }
            switch matchKind {
            case .exact:
                list[index].match = .exact(trimmed)
            case .prefix:
                list[index].match = .prefix(trimmed)
            }
            cfg.appLayoutRules = list
        }
        refreshResolvedIcon()
    }
}

// MARK: - Shared

/// Internal (not file-private) so other Settings sub-views (DeviceRow,
/// future tabs) can share the safe subscript pattern.
extension Array {
    /// Safe subscript so an out-of-bounds index returns nil instead of
    /// crashing. Used in SwiftUI rows that can briefly read a stale index
    /// after a removal before the parent re-renders.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

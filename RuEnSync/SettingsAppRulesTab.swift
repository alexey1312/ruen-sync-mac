import SwiftUI

// MARK: - AppRulesTab

struct SettingsAppRulesTab: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("App layout rules")
                .font(.headline)
            Text(
                "Match by exact bundle ID or by prefix. Exact wins over prefix; among prefixes, the longest match wins."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            let rules = model.config.appLayoutRules ?? []
            if rules.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "app.badge")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("No rules yet. Add one below.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules.indices, id: \.self) { idx in
                        AppRuleRow(model: model, index: idx)
                    }
                }
                .listStyle(.bordered)
            }

            HStack {
                Spacer()
                Button("Add rule") {
                    model.editConfig {
                        var list = $0.appLayoutRules ?? []
                        let firstLayout = $0.layouts.first ?? "ABC"
                        list.append(.exact("com.example.app", layout: firstLayout))
                        $0.appLayoutRules = list
                    }
                }
            }
        }
        .padding()
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
    @FocusState private var bundleFocused: Bool

    var body: some View {
        guard let rule = (model.config.appLayoutRules ?? [])[safe: index] else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 8) {
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
            }
            .padding(.vertical, 2)
            .onAppear { syncDraftFromRule(rule) }
            .onChange(of: rule) { _, newRule in syncDraftFromRule(newRule) }
        )
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

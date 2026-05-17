import Foundation

// MARK: - AppLayoutRuleMatching

/// Pure matcher for per-app layout rules. Lives outside AppModel so it can
/// be called from `nonisolated` test contexts and reused if we ever surface
/// the lookup in a CLI / diagnostics tool. Behaviour:
///
/// 1. Exact `bundleId` match wins over any prefix match.
/// 2. Among prefix matches, the **longest** prefix wins. This makes
///    `com.jetbrains.AppCode` correctly pick a `com.jetbrains.` rule over a
///    broader `com.` catch-all, regardless of the rules' order in the array.
/// 3. Rules without either `bundleId` or `bundleIdPrefix` are inert — they
///    can't match anything. We don't reject the config; the user's intent
///    might be to disable a rule by clearing both fields.
enum AppLayoutRuleMatching {
    static func match(rules: [Config.AppLayoutRule], bundleId: String) -> Config.AppLayoutRule? {
        if let exact = rules.first(where: { $0.bundleId == bundleId }) {
            return exact
        }
        return rules
            .filter { rule in
                guard let prefix = rule.bundleIdPrefix else { return false }
                return bundleId.hasPrefix(prefix)
            }
            .max(by: { ($0.bundleIdPrefix?.count ?? 0) < ($1.bundleIdPrefix?.count ?? 0) })
    }
}

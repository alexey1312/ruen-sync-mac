import Foundation

// MARK: - AppLayoutRuleMatching

/// Pure matcher for per-app layout rules. Lives outside AppModel so it can
/// be called from `nonisolated` test contexts and reused if we ever surface
/// the lookup in a CLI / diagnostics tool. Behaviour:
///
/// 1. Exact `.exact(bundleId)` match wins over any `.prefix` match.
/// 2. Among `.prefix` matches, the **longest** prefix wins. This makes
///    `com.jetbrains.AppCode` correctly pick a `com.jetbrains.` rule over a
///    broader `com.` catch-all, regardless of the rules' order in the array.
///
/// "Inert" rules cannot exist at the type level — `AppLayoutRule.Match` is a
/// sum type so a rule with neither bundleId nor prefix is unrepresentable.
enum AppLayoutRuleMatching {
    static func match(rules: [Config.AppLayoutRule], bundleId: String) -> Config.AppLayoutRule? {
        if let exact = rules.first(where: {
            if case let .exact(id) = $0.match { id == bundleId } else { false }
        }) {
            return exact
        }
        return rules
            .filter { rule in
                guard case let .prefix(prefix) = rule.match else { return false }
                return bundleId.hasPrefix(prefix)
            }
            .max(by: { lhs, rhs in
                let l = if case let .prefix(p) = lhs.match { p.count } else { 0 }
                let r = if case let .prefix(p) = rhs.match { p.count } else { 0 }
                return l < r
            })
    }
}

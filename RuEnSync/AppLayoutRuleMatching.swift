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
        var bestMatch: Config.AppLayoutRule?
        var longestPrefixLength = -1

        for rule in rules {
            if case let .prefix(prefix) = rule.match, bundleId.hasPrefix(prefix) {
                if prefix.count > longestPrefixLength {
                    bestMatch = rule
                    longestPrefixLength = prefix.count
                }
            }
        }

        return bestMatch
    }
}

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
        // `.lazy` keeps the single-pass, zero-intermediate-array property of an
        // imperative loop while staying declarative — and computes `prefix.count`
        // once per matching rule rather than recomputing it inside `max`'s
        // comparator. `max(by:)` returns the *first* maximal element on ties, so
        // the "earliest longest prefix wins" tie-break matches the doc comment.
        return rules.lazy
            .compactMap { rule -> (rule: Config.AppLayoutRule, count: Int)? in
                guard case let .prefix(prefix) = rule.match, bundleId.hasPrefix(prefix) else { return nil }
                return (rule, prefix.count)
            }
            .max(by: { $0.count < $1.count })?
            .rule
    }
}

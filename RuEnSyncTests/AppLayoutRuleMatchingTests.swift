import Foundation
@testable import RuEnSync
import Testing

struct AppLayoutRuleMatchingTests {
    @Test("exact bundleId wins over a prefix that also matches")
    func exactBeatsPrefix() {
        let rules: [Config.AppLayoutRule] = [
            .prefix("com.jetbrains.", layout: "ABC"),
            .exact("com.jetbrains.AppCode", layout: "Russian"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.jetbrains.AppCode")
        #expect(match?.layout == "Russian")
    }

    @Test("longest prefix wins when multiple prefixes match")
    func longestPrefixWins() {
        let rules: [Config.AppLayoutRule] = [
            .prefix("com.", layout: "ABC"),
            .prefix("com.jetbrains.", layout: "Russian"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.jetbrains.AppCode")
        // The longer prefix is specifically about "com.jetbrains.*", so it
        // wins over the more permissive "com.*".
        #expect(match?.bundleIdPrefix == "com.jetbrains.")
    }

    @Test("no match returns nil")
    func noMatch() {
        let rules: [Config.AppLayoutRule] = [
            .exact("com.apple.dt.Xcode", layout: "ABC"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.apple.Notes")
        #expect(match == nil)
    }

    @Test("empty rules returns nil")
    func emptyRules() {
        #expect(AppLayoutRuleMatching.match(rules: [], bundleId: "com.apple.Notes") == nil)
    }

    @Test("tie-break: earliest longest prefix wins")
    func earliestLongestPrefixWins() {
        let rules: [Config.AppLayoutRule] = [
            .prefix("com.jetbrains.", layout: "ABC"),
            .prefix("com.jetbrains.", layout: "Russian"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.jetbrains.AppCode")
        // Since both prefixes have the same length ("com.jetbrains."),
        // the rule appearing earliest in the array should win.
        #expect(match?.layout == "ABC")
    }

    @Test("exact match wins regardless of rule order")
    func exactWinsRegardlessOfOrder() {
        let rules: [Config.AppLayoutRule] = [
            .prefix("com.jetbrains.", layout: "ABC"),
            .exact("com.jetbrains.AppCode", layout: "Russian"),
            .prefix("com.jetbrains.", layout: "EN"),
        ]
        let match1 = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.jetbrains.AppCode")
        #expect(match1?.layout == "Russian")

        let rulesReversed: [Config.AppLayoutRule] = [
            .exact("com.jetbrains.AppCode", layout: "Russian"),
            .prefix("com.jetbrains.", layout: "ABC"),
        ]
        let match2 = AppLayoutRuleMatching.match(rules: rulesReversed, bundleId: "com.jetbrains.AppCode")
        #expect(match2?.layout == "Russian")
    }

    @Test("prefix exactly equaling bundle id")
    func prefixExactlyEqualingBundleId() {
        let rules: [Config.AppLayoutRule] = [
            .prefix("com.jetbrains.AppCode", layout: "ABC"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.jetbrains.AppCode")
        #expect(match?.layout == "ABC")
    }

    @Test("bundle id shorter than prefix does not match")
    func bundleIdShorterThanPrefix() {
        let rules: [Config.AppLayoutRule] = [
            .prefix("com.jetbrains.AppCode", layout: "ABC"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.jetbrains.")
        #expect(match == nil)
    }

    @Test("tie-break: first exact match wins")
    func firstExactMatchWins() {
        let rules: [Config.AppLayoutRule] = [
            .exact("com.apple.dt.Xcode", layout: "ABC"),
            .exact("com.apple.dt.Xcode", layout: "Russian"),
        ]
        let match = AppLayoutRuleMatching.match(rules: rules, bundleId: "com.apple.dt.Xcode")
        #expect(match?.layout == "ABC")
    }
}

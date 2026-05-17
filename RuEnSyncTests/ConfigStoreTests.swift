import Foundation
@testable import RuEnSync
import Testing

struct ConfigDecodingTests {
    @Test("decodes qmk-hid-host-style config")
    func decodesCompatConfig() throws {
        let json = Data("""
        {
          "devices": [{ "productId": "0x0001", "name": "Corne" }],
          "layouts": ["ABC", "Russian"],
          "reconnectDelay": 5000
        }
        """.utf8)

        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.layouts == ["ABC", "Russian"])
        #expect(config.devices.count == 1)
        #expect(config.devices[0].productId == "0x0001")
        #expect(config.devices[0].usage == nil)
        #expect(config.devices[0].usagePage == nil)
    }

    @Test("decodes explicit usage/usagePage when provided")
    func decodesExplicitUsage() throws {
        let json = Data("""
        {
          "devices": [{
            "productId": "0x1234",
            "name": "Test",
            "usagePage": 65376,
            "usage": 97
          }],
          "layouts": ["EN"]
        }
        """.utf8)

        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.devices[0].usagePage == 0xFF60)
        #expect(config.devices[0].usage == 0x61)
    }

    @Test("decodes multiple devices in order")
    func decodesMultipleDevices() throws {
        let json = Data("""
        {
          "devices": [
            { "productId": "0x0001", "name": "Corne" },
            { "productId": "0x0002", "name": "Lily58" }
          ],
          "layouts": ["ABC", "Russian"]
        }
        """.utf8)

        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.devices.count == 2)
        #expect(config.devices[0].name == "Corne")
        #expect(config.devices[1].name == "Lily58")

        let resolved = config.devices.compactMap(ResolvedDevice.init)
        #expect(resolved.count == 2)
        #expect(resolved[0].productId == 0x0001)
        #expect(resolved[1].productId == 0x0002)
    }

    @Test("legacy config without appLayoutRules still decodes")
    func decodesLegacyConfigWithoutRules() throws {
        // Mirror an existing user's config.json. Adding new optional fields
        // must not break loading — backward compatibility is non-negotiable.
        let json = Data("""
        {
          "devices": [{ "productId": "0x0001", "name": "Corne" }],
          "layouts": ["ABC", "Russian"]
        }
        """.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.appLayoutRules == nil)
        #expect(config.appLayoutSwitchingEnabled == nil)
    }

    @Test("decodes appLayoutRules with exact and prefix entries")
    func decodesRules() throws {
        let json = Data("""
        {
          "devices": [{ "productId": "0x0001", "name": "Corne" }],
          "layouts": ["ABC", "Russian"],
          "appLayoutRules": [
            { "bundleId": "com.apple.dt.Xcode", "layout": "ABC" },
            { "bundleIdPrefix": "com.jetbrains.", "layout": "ABC" },
            { "bundleId": "com.tinyspeck.slackmacgap", "layout": "Russian" }
          ],
          "appLayoutSwitchingEnabled": true
        }
        """.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.appLayoutRules?.count == 3)
        #expect(config.appLayoutRules?[0].match == .exact("com.apple.dt.Xcode"))
        #expect(config.appLayoutRules?[1].match == .prefix("com.jetbrains."))
        #expect(config.appLayoutSwitchingEnabled == true)
    }

    @Test("rejects rule with neither bundleId nor bundleIdPrefix")
    func rejectsInertRule() {
        // Schema invariant: a rule must carry a match clause. The decoder
        // refuses inert rules at parse time so the rest of the app can rely
        // on the sum-type guarantee inside `AppLayoutRule.Match`.
        let json = Data("""
        {
          "devices": [],
          "layouts": ["ABC"],
          "appLayoutRules": [
            { "layout": "ABC" }
          ]
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Config.self, from: json)
        }
    }

    @Test("round-trips appLayoutRules through encode + decode")
    func roundTripRules() throws {
        let config = Config(
            devices: [],
            layouts: ["ABC", "Russian"],
            appLayoutRules: [
                .exact("com.apple.dt.Xcode", layout: "ABC"),
                .prefix("com.jetbrains.", layout: "Russian"),
            ],
            appLayoutSwitchingEnabled: true,
            debug: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.appLayoutRules == config.appLayoutRules)
    }
}

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
}

struct ResolvedDeviceTests {
    @Test("parses 0x-prefixed product id")
    func parsesHexProductId() {
        let device = Config.Device(name: "x", productId: "0x0001", usagePage: nil, usage: nil)
        let resolved = ResolvedDevice(device)
        #expect(resolved?.productId == 1)
        #expect(resolved?.usagePage == 0xFF60)
        #expect(resolved?.usage == 0x61)
    }

    @Test("parses decimal product id")
    func parsesDecimalProductId() {
        let device = Config.Device(name: "x", productId: "42", usagePage: nil, usage: nil)
        #expect(ResolvedDevice(device)?.productId == 42)
    }

    @Test("rejects empty product id")
    func rejectsEmpty() {
        let device = Config.Device(name: "x", productId: "", usagePage: nil, usage: nil)
        #expect(ResolvedDevice(device) == nil)
    }

    @Test("uses overrides for usage and usagePage")
    func usesOverrides() {
        let device = Config.Device(
            name: "x",
            productId: "0x1",
            usagePage: 0x1234,
            usage: 0x99
        )
        let resolved = ResolvedDevice(device)
        #expect(resolved?.usagePage == 0x1234)
        #expect(resolved?.usage == 0x99)
    }
}

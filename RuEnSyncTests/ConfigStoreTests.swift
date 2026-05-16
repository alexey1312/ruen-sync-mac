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

//
//  LinkEndpointTests.swift
//  BLESwiftLinkTests
//

import BLESwiftLink
import Foundation
import Testing

@Suite("LinkEndpoint")
struct LinkEndpointTests {

    @Test("Default endpoint")
    func defaultEndpoint() {
        #expect(LinkEndpoint.default == LinkEndpoint(host: "127.0.0.1", port: 45541))
        #expect(LinkEndpoint.default.description == "127.0.0.1:45541")
    }

    @Test("Parses host:port")
    func parse() {
        #expect(LinkEndpoint(string: "localhost:8080") == LinkEndpoint(host: "localhost", port: 8080))
        #expect(LinkEndpoint(string: "nope") == nil)
        #expect(LinkEndpoint(string: "h:notaport") == nil)
        #expect(LinkEndpoint(string: "h:70000") == nil)
        #expect(LinkEndpoint(string: ":1") == nil)
    }

    @Test("Parses a bracketed IPv6 host")
    func parseIPv6() {
        // Brackets, because the address is itself full of colons: the last-colon split alone
        // could not tell the port from the address.
        #expect(LinkEndpoint(string: "[::1]:8080") == LinkEndpoint(host: "::1", port: 8080))
        #expect(LinkEndpoint(string: "[fe80::1]:1") == LinkEndpoint(host: "fe80::1", port: 1))
        #expect(LinkEndpoint(string: "[::1]") == nil)
        #expect(LinkEndpoint(string: "[]:8080") == nil)
        #expect(LinkEndpoint(string: "[::1]:notaport") == nil)
        #expect(LinkEndpoint(string: "[::1]8080") == nil)
    }

    @Test("An IPv6 endpoint round-trips through its description")
    func ipv6RoundTrip() {
        let endpoint = LinkEndpoint(host: "::1", port: 45541)
        #expect(endpoint.description == "[::1]:45541")
        #expect(LinkEndpoint(string: endpoint.description) == endpoint)
        #expect(LinkEndpoint.default.description == "127.0.0.1:45541")
    }

    @Test(
        "Recognizes every loopback host, and nothing else",
        arguments: [
            ("127.0.0.1", true),
            ("127.0.0.2", true),
            ("127.255.255.254", true),
            ("localhost", true),
            ("::1", true),
            ("[::1]", true),
            ("128.0.0.1", false),
            ("127.0.0", false),
            ("127.0.0.256", false),
            ("::2", false),
            ("fe80::1", false),
            ("0.0.0.0", false),
            ("example.com", false)
        ]
    )
    func loopbackClassification(host: String, isLoopback: Bool) {
        #expect(LinkEndpoint(host: host, port: 1).isLoopback == isLoopback)
    }

    @Test("Reads BLESWIFT_LINK from the environment")
    func environment() {
        #expect(LinkEndpoint.fromEnvironment(["BLESWIFT_LINK": "10.0.0.2:9"]) == LinkEndpoint(host: "10.0.0.2", port: 9))
        #expect(LinkEndpoint.fromEnvironment([:]) == nil)
        #expect(LinkEndpoint.fromEnvironment(["BLESWIFT_LINK": "garbage"]) == nil)
    }
    @Test("localhost is normalized to the IPv4 loopback literal, on every route in")
    func localhostIsNormalized() throws {
        // The name resolves to both loopback families, so a listener and a client handed the
        // same string could otherwise bind and dial different addresses.
        #expect(LinkEndpoint(host: "localhost", port: 1).host == "127.0.0.1")
        #expect(LinkEndpoint(host: "LocalHost", port: 1).host == "127.0.0.1")
        #expect(LinkEndpoint(host: "localhost", port: 1) == LinkEndpoint(host: "127.0.0.1", port: 1))
        #expect(LinkEndpoint(host: "localhost", port: 1).description == "127.0.0.1:1")
        #expect(LinkEndpoint(string: "localhost:8080")?.host == "127.0.0.1")
        #expect(LinkEndpoint.fromEnvironment(["BLESWIFT_LINK": "localhost:9"]) == LinkEndpoint(host: "127.0.0.1", port: 9))

        var mutated = LinkEndpoint(host: "127.0.0.1", port: 1)
        mutated.host = "localhost"
        #expect(mutated.host == "127.0.0.1")

        // Nothing else is touched, and a hostname that merely contains it is not the name.
        #expect(LinkEndpoint(host: "localhost.example.com", port: 1).host == "localhost.example.com")
        #expect(LinkEndpoint(host: "::1", port: 1).host == "::1")
    }

    @Test("A decoded endpoint keeps the encoded shape and is normalized like any other")
    func codingRoundTrip() throws {
        let encoded = try JSONEncoder().encode(LinkEndpoint(host: "127.0.0.1", port: 45541))
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"host\""))
        #expect(try JSONDecoder().decode(LinkEndpoint.self, from: encoded) == LinkEndpoint.default)

        // A value encoded before the normalization existed still reads back agreeing with
        // what a listener binds.
        let legacy = Data(#"{"host":"localhost","port":45541}"#.utf8)
        #expect(try JSONDecoder().decode(LinkEndpoint.self, from: legacy) == LinkEndpoint.default)
    }
}

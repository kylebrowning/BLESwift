//
//  LinkEndpointTests.swift
//  BLESwiftLinkTests
//

import BLESwiftLink
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
}

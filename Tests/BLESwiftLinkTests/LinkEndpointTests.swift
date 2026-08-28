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

    @Test("Reads BLESWIFT_LINK from the environment")
    func environment() {
        #expect(LinkEndpoint.fromEnvironment(["BLESWIFT_LINK": "10.0.0.2:9"]) == LinkEndpoint(host: "10.0.0.2", port: 9))
        #expect(LinkEndpoint.fromEnvironment([:]) == nil)
        #expect(LinkEndpoint.fromEnvironment(["BLESWIFT_LINK": "garbage"]) == nil)
    }
}

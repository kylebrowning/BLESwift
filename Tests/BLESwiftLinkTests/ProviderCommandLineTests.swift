//
//  ProviderCommandLineTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Testing

@Suite("ProviderCommandLine")
struct ProviderCommandLineTests {

    @Test("Defaults")
    func defaults() throws {
        let options = try ProviderCommandLine.parse([])
        #expect(options.endpoint == .default)
        #expect(options.codec == .binaryPropertyList)
        #expect(options.passthrough == false)
        #expect(options.fixturePaths == [])
        #expect(options.showHelp == false)
    }

    @Test("Endpoint defaults to the environment when set")
    func environmentDefault() throws {
        let options = try ProviderCommandLine.parse([], environment: ["BLESWIFT_LINK": "10.0.0.5:9"])
        #expect(options.endpoint == LinkEndpoint(host: "10.0.0.5", port: 9))
    }

    @Test("--passthrough sets passthrough")
    func passthrough() throws {
        let options = try ProviderCommandLine.parse(["--passthrough"])
        #expect(options.passthrough == true)
    }

    @Test("--fixture is repeatable and preserves order")
    func repeatedFixture() throws {
        let options = try ProviderCommandLine.parse(["--fixture", "a.json", "--fixture", "b.json"])
        #expect(options.fixturePaths == ["a.json", "b.json"])
    }

    @Test("--listen sets the endpoint")
    func listen() throws {
        let options = try ProviderCommandLine.parse(["--listen", "0.0.0.0:1234"])
        #expect(options.endpoint == LinkEndpoint(host: "0.0.0.0", port: 1234))
    }

    @Test("--listen overrides the environment default")
    func listenOverridesEnvironment() throws {
        let options = try ProviderCommandLine.parse(
            ["--listen", "192.168.0.1:1"],
            environment: ["BLESWIFT_LINK": "10.0.0.5:9"]
        )
        #expect(options.endpoint == LinkEndpoint(host: "192.168.0.1", port: 1))
    }

    @Test("--json sets the JSON codec")
    func json() throws {
        let options = try ProviderCommandLine.parse(["--json"])
        #expect(options.codec == .json)
    }

    @Test("--help short-circuits, even with garbage after it")
    func helpLongFlag() throws {
        let options = try ProviderCommandLine.parse(["--help", "--nope", "--listen", "bad"])
        #expect(options.showHelp == true)
    }

    @Test("-h short-circuits, even with garbage after it")
    func helpShortFlag() throws {
        let options = try ProviderCommandLine.parse(["-h", "--nope"])
        #expect(options.showHelp == true)
    }

    @Test("Unknown flag throws unknownFlag")
    func unknownFlag() {
        #expect {
            try ProviderCommandLine.parse(["--nope"])
        } throws: { error in
            error as? ProviderCommandLine.ParseError == .unknownFlag("--nope")
        }
    }

    @Test("--fixture at the end of arguments throws missingValue")
    func missingFixtureValue() {
        #expect {
            try ProviderCommandLine.parse(["--fixture"])
        } throws: { error in
            error as? ProviderCommandLine.ParseError == .missingValue("--fixture")
        }
    }

    @Test("--listen at the end of arguments throws missingValue")
    func missingListenValue() {
        #expect {
            try ProviderCommandLine.parse(["--listen"])
        } throws: { error in
            error as? ProviderCommandLine.ParseError == .missingValue("--listen")
        }
    }

    @Test("--listen with an unparseable value throws invalidEndpoint")
    func invalidEndpoint() {
        #expect {
            try ProviderCommandLine.parse(["--listen", "bad"])
        } throws: { error in
            error as? ProviderCommandLine.ParseError == .invalidEndpoint("bad")
        }
    }

    @Test("Every flag together")
    func everyFlag() throws {
        let options = try ProviderCommandLine.parse([
            "--passthrough",
            "--fixture", "one.json",
            "--fixture", "two.json",
            "--listen", "127.0.0.1:9999",
            "--json"
        ])
        #expect(options.passthrough == true)
        #expect(options.fixturePaths == ["one.json", "two.json"])
        #expect(options.endpoint == LinkEndpoint(host: "127.0.0.1", port: 9999))
        #expect(options.codec == .json)
        #expect(options.showHelp == false)
    }

    @Test("usage mentions every flag and the environment variable")
    func usageMentionsEveryFlag() {
        let usage = ProviderCommandLine.usage
        #expect(usage.contains("--passthrough"))
        #expect(usage.contains("--fixture"))
        #expect(usage.contains("--listen"))
        #expect(usage.contains("--json"))
        #expect(usage.contains("-h"))
        #expect(usage.contains("--help"))
        #expect(usage.contains("BLESWIFT_LINK"))
    }

    @Test("A loopback endpoint warns about nothing")
    func loopbackEndpointsDoNotWarn() {
        #expect(ProviderCommandLine.nonLoopbackWarning(for: .default) == nil)
        #expect(ProviderCommandLine.nonLoopbackWarning(for: LinkEndpoint(host: "127.0.0.1", port: 1)) == nil)
        #expect(ProviderCommandLine.nonLoopbackWarning(for: LinkEndpoint(host: "localhost", port: 1)) == nil)
        #expect(LinkEndpoint.default.isLoopback)
    }

    @Test("A non-loopback endpoint warns that the link is unauthenticated")
    func nonLoopbackEndpointsWarn() throws {
        let options = try ProviderCommandLine.parse(["--listen", "0.0.0.0:45541"])
        let warning = try #require(ProviderCommandLine.nonLoopbackWarning(for: options.endpoint))
        #expect(warning.contains("non-loopback"))
        #expect(warning.contains("unauthenticated"))
        #expect(!LinkEndpoint(host: "192.168.1.10", port: 45541).isLoopback)
        #expect(ProviderCommandLine.nonLoopbackWarning(for: LinkEndpoint(host: "192.168.1.10", port: 1)) != nil)
    }
}
#endif

//
//  ProviderCommandTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Foundation
import Testing

/// The subcommands of `bleswift-provider` and the launch agent that `install-agent` writes.
@Suite("ProviderCommandLine subcommands")
struct ProviderCommandTests {

    private typealias CommandLine = ProviderCommandLine

    @Test("No subcommand serves with the whole array")
    func serveIsTheDefault() throws {
        #expect(try CommandLine.parseCommand([], environment: [:]) == .serve(CommandLine.Options()))
        let command = try CommandLine.parseCommand(["--passthrough", "--verbose"], environment: [:])
        #expect(command == .serve(CommandLine.Options(passthrough: true, verbose: true)))
    }

    @Test("-h or --help selects help")
    func help() throws {
        #expect(try CommandLine.parseCommand(["-h"], environment: [:]) == .help)
        #expect(try CommandLine.parseCommand(["--help"], environment: [:]) == .help)
        #expect(try CommandLine.parseCommand(["--passthrough", "--help"], environment: [:]) == .help)
        #expect(try CommandLine.parseCommand(["status", "--json", "-h"], environment: [:]) == .help)
        #expect(try CommandLine.parseCommand(["capture", "--help"], environment: [:]) == .help)
        #expect(try CommandLine.parseCommand(["install-agent", "--help"], environment: [:]) == .help)
        #expect(try CommandLine.parseCommand(["uninstall-agent", "-h"], environment: [:]) == .help)
    }

    @Test("status takes --listen, BLESWIFT_LINK, and --json")
    func status() throws {
        #expect(try CommandLine.parseCommand(["status"], environment: [:]) == .status(CommandLine.StatusOptions()))
        let fromEnvironment = try CommandLine.parseCommand(["status"], environment: ["BLESWIFT_LINK": "127.0.0.1:9"])
        #expect(fromEnvironment == .status(CommandLine.StatusOptions(endpoint: LinkEndpoint(host: "127.0.0.1", port: 9))))
        let explicit = try CommandLine.parseCommand(
            ["status", "--listen", "127.0.0.1:7", "--json"],
            environment: ["BLESWIFT_LINK": "127.0.0.1:9"]
        )
        #expect(explicit == .status(CommandLine.StatusOptions(endpoint: LinkEndpoint(host: "127.0.0.1", port: 7), json: true)))
        #expect(throws: CommandLine.ParseError.unknownFlag("--passthrough")) {
            try CommandLine.parseCommand(["status", "--passthrough"], environment: [:])
        }
        #expect(throws: CommandLine.ParseError.invalidEndpoint("bad")) {
            try CommandLine.parseCommand(["status", "--listen", "bad"], environment: [:])
        }
    }

    @Test("capture takes its flags and checks their values")
    func capture() throws {
        #expect(try CommandLine.parseCommand(["capture"], environment: [:]) == .capture(CommandLine.CaptureOptions()))
        let command = try CommandLine.parseCommand([
            "capture", "--duration", "2.5", "--name", "HRM", "--name", "Band",
            "--service", "180D", "--all", "--output", "out.json",
        ], environment: [:])
        #expect(command == .capture(CommandLine.CaptureOptions(
            duration: .milliseconds(2500),
            names: ["HRM", "Band"],
            services: ["180D"],
            all: true,
            outputPath: "out.json"
        )))
        for bad in ["0", "-1", "inf", "nan", "ten"] {
            #expect(throws: CommandLine.ParseError.invalidValue(flag: "--duration", value: bad)) {
                try CommandLine.parseCommand(["capture", "--duration", bad], environment: [:])
            }
        }
        #expect(throws: CommandLine.ParseError.invalidValue(flag: "--service", value: "zzzz")) {
            try CommandLine.parseCommand(["capture", "--service", "zzzz"], environment: [:])
        }
        #expect(throws: CommandLine.ParseError.missingValue("--name")) {
            try CommandLine.parseCommand(["capture", "--name"], environment: [:])
        }
    }

    @Test("install-agent keeps its arguments as given and ignores BLESWIFT_LINK")
    func installAgent() throws {
        let arguments = ["--passthrough", "--fixture", "a.json"]
        let command = try CommandLine.parseCommand(
            ["install-agent"] + arguments,
            environment: ["BLESWIFT_LINK": "10.0.0.5:9"]
        )
        #expect(command == .installAgent(
            CommandLine.Options(passthrough: true, fixturePaths: ["a.json"]),
            arguments: arguments
        ))
        #expect(throws: CommandLine.ParseError.unknownFlag("--nope")) {
            try CommandLine.parseCommand(["install-agent", "--nope"], environment: [:])
        }
    }

    @Test("uninstall-agent takes no arguments")
    func uninstallAgent() throws {
        #expect(try CommandLine.parseCommand(["uninstall-agent"], environment: [:]) == .uninstallAgent)
        #expect(throws: CommandLine.ParseError.unknownFlag("--passthrough")) {
            try CommandLine.parseCommand(["uninstall-agent", "--passthrough"], environment: [:])
        }
    }

    @Test("usage lists every subcommand")
    func usageListsSubcommands() {
        let usage = CommandLine.usage
        for word in ["Commands:", "status", "capture", "install-agent", "uninstall-agent",
                     "--duration", "--name", "--service", "--all", "--output", "--verbose"] {
            #expect(usage.contains(word), "\(word)")
        }
    }

    @Test("The agent's property list has the launchd keys")
    func agentPropertyList() throws {
        let plist = ProviderAgent.propertyList(
            executable: "/opt/homebrew/bin/bleswift-provider",
            arguments: ["--passthrough"],
            logPath: "/Users/someone/Library/Logs/bleswift-provider.log"
        )
        #expect(plist["Label"] as? String == "com.kylebrowning.bleswift-provider")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/homebrew/bin/bleswift-provider", "--passthrough"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/Users/someone/Library/Logs/bleswift-provider.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/someone/Library/Logs/bleswift-provider.log")
        #expect(plist.count == 6)
        // The dictionary must serialize as a property list.
        _ = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @Test("The agent must listen on loopback")
    func agentRejectsNonLoopback() throws {
        #expect(ProviderAgent.endpointError(for: .default) == nil)
        #expect(ProviderAgent.endpointError(for: LinkEndpoint(host: "127.0.0.1", port: 1)) == nil)
        let command = try CommandLine.parseCommand(["install-agent", "--listen", "0.0.0.0:45541"], environment: [:])
        guard case .installAgent(let options, _) = command else {
            Issue.record("expected installAgent, got \(command)")
            return
        }
        let error = try #require(ProviderAgent.endpointError(for: options.endpoint))
        #expect(error.contains("loopback"))
    }

    @Test("The executable path is absolute and keeps symbolic links")
    func executablePath() {
        #expect(ProviderAgent.executablePath(argument: "/opt/homebrew/bin/bleswift-provider", currentDirectory: "/tmp")
            == "/opt/homebrew/bin/bleswift-provider")
        #expect(ProviderAgent.executablePath(argument: ".build/debug/bleswift-provider", currentDirectory: "/work/repo")
            == "/work/repo/.build/debug/bleswift-provider")
        #expect(ProviderAgent.executablePath(argument: "./bin/../bin/tool", currentDirectory: "/work")
            == "/work/bin/tool")
        #expect(ProviderAgent.buildDirectoryWarning(for: "/work/repo/.build/debug/bleswift-provider") != nil)
        #expect(ProviderAgent.buildDirectoryWarning(for: "/opt/homebrew/bin/bleswift-provider") == nil)
    }
}
#endif

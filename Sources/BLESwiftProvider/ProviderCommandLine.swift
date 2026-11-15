//
//  ProviderCommandLine.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Foundation

/// The command-line interface for the `bleswift-provider` executable.
///
/// The grammar is small: six flags, and one of them can repeat. Thus ``parse(_:environment:)``
/// reads the argument array directly and the module has no argument-parsing dependency.
public enum ProviderCommandLine {

    /// The parsed result of ``parse(_:environment:)``.
    public struct Options: Sendable, Equatable {
        /// Where the provider listens: the `--listen` value, else `BLESWIFT_LINK`, else
        /// `LinkEndpoint.default`.
        public var endpoint: LinkEndpoint
        /// The codec with which the provider encodes. `--json` selects `LinkCodec.json`. The
        /// default is `LinkCodec.binaryPropertyList`.
        public var codec: LinkCodec
        /// Whether the arguments contain `--passthrough`.
        public var passthrough: Bool
        /// The paths that follow `--fixture`, in argument order.
        public var fixturePaths: [String]
        /// Whether the arguments contain `--verbose`. When `true`, the provider logs one line for
        /// each link message in each direction.
        public var verbose: Bool
        /// Whether the arguments contain `-h`/`--help`. When `true`, parsing stopped at the flag
        /// and the other fields are incomplete.
        public var showHelp: Bool

        /// Creates an `Options` value directly, with the defaults of ``parse(_:environment:)``.
        public init(
            endpoint: LinkEndpoint = .default,
            codec: LinkCodec = .binaryPropertyList,
            passthrough: Bool = false,
            fixturePaths: [String] = [],
            verbose: Bool = false,
            showHelp: Bool = false
        ) {
            self.endpoint = endpoint
            self.codec = codec
            self.passthrough = passthrough
            self.fixturePaths = fixturePaths
            self.verbose = verbose
            self.showHelp = showHelp
        }
    }

    /// The errors that ``parse(_:environment:)`` throws.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        /// An argument that is not one of the known flags.
        case unknownFlag(String)
        /// A flag that takes a value has no argument after it.
        case missingValue(String)
        /// The value of `--listen` is not valid `host:port`.
        case invalidEndpoint(String)
        /// The value of a flag is not valid for that flag.
        case invalidValue(flag: String, value: String)

        public var description: String {
            switch self {
            case .unknownFlag(let flag):
                "unrecognized flag \(flag)"
            case .missingValue(let flag):
                "\(flag) requires a value"
            case .invalidEndpoint(let value):
                "\(value) is not a valid host:port endpoint"
            case .invalidValue(let flag, let value):
                "\(value) is not a valid value for \(flag)"
            }
        }
    }

    /// Parses `arguments` (excluding `argv[0]`) into ``Options``.
    ///
    /// `-h`/`--help` ends parsing early. The returned `Options` has `showHelp` set to `true`. The
    /// parser does not inspect any later argument, valid or not.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments, not including the executable path.
    ///   - environment: The source of `BLESWIFT_LINK` when `--listen` is absent. The default is
    ///     the process environment.
    /// - Throws: ``ParseError`` for an unrecognized flag, a value-taking flag with nothing
    ///   after it, or an unparseable `--listen` value.
    public static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Options {
        var options = Options(endpoint: LinkEndpoint.fromEnvironment(environment) ?? .default)
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.showHelp = true
                return options
            case "--passthrough":
                options.passthrough = true
            case "--json":
                options.codec = .json
            case "--verbose":
                options.verbose = true
            case "--fixture":
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { throw ParseError.missingValue(argument) }
                options.fixturePaths.append(arguments[index])
            case "--listen":
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { throw ParseError.missingValue(argument) }
                let value = arguments[index]
                guard let endpoint = LinkEndpoint(string: value) else {
                    throw ParseError.invalidEndpoint(value)
                }
                options.endpoint = endpoint
            default:
                throw ParseError.unknownFlag(argument)
            }
            index = arguments.index(after: index)
        }
        return options
    }

    /// The options of the `status` subcommand.
    public struct StatusOptions: Sendable, Equatable {
        /// The provider to ask: the `--listen` value, else `BLESWIFT_LINK`, else
        /// `LinkEndpoint.default`.
        public var endpoint: LinkEndpoint
        /// Whether the arguments contain `--json`. When `true`, the status prints as JSON.
        public var json: Bool

        /// Creates a `StatusOptions` value directly, with the defaults of
        /// ``parseCommand(_:environment:)``.
        public init(endpoint: LinkEndpoint = .default, json: Bool = false) {
            self.endpoint = endpoint
            self.json = json
        }
    }

    /// The options of the `capture` subcommand.
    public struct CaptureOptions: Sendable, Equatable {
        /// How long to scan. The default is ten seconds.
        public var duration: Duration
        /// The values of `--name`, in argument order. A device matches if its name contains one
        /// of them. Case does not matter.
        public var names: [String]
        /// The values of `--service`, in argument order. A device matches if it advertises one
        /// of them.
        public var services: [String]
        /// Whether the arguments contain `--all`. When `true`, the capture selects every listed
        /// device.
        public var all: Bool
        /// The value of `--output`. If it is `nil`, the capture writes to standard output.
        public var outputPath: String?

        /// Creates a `CaptureOptions` value directly, with the defaults of
        /// ``parseCommand(_:environment:)``.
        public init(
            duration: Duration = .seconds(10),
            names: [String] = [],
            services: [String] = [],
            all: Bool = false,
            outputPath: String? = nil
        ) {
            self.duration = duration
            self.names = names
            self.services = services
            self.all = all
            self.outputPath = outputPath
        }
    }

    /// The subcommand that ``parseCommand(_:environment:)`` selects.
    public enum Command: Equatable {
        /// Run the provider. This is the default when the first argument is not a subcommand.
        case serve(Options)
        /// Print the status of a running provider.
        case status(StatusOptions)
        /// Scan for real devices and write a fixture document for them.
        case capture(CaptureOptions)
        /// Install a launch agent that runs the provider. `arguments` is the serve argument
        /// array exactly as given after `install-agent`.
        case installAgent(Options, arguments: [String])
        /// Remove the launch agent.
        case uninstallAgent
        /// Print the usage text.
        case help
    }

    /// Parses `arguments` (excluding `argv[0]`) into a ``Command``.
    ///
    /// The first argument selects the subcommand: `status`, `capture`, `install-agent`, or
    /// `uninstall-agent`. Any other first argument selects ``Command/serve(_:)``, which
    /// ``parse(_:environment:)`` parses from the whole array. `-h` or `--help` in the arguments
    /// gives ``Command/help``.
    ///
    /// `install-agent` parses its arguments with an empty environment. The agent runs under
    /// `launchd`, which does not pass `BLESWIFT_LINK`, so only `--listen` sets its endpoint.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments, not including the executable path.
    ///   - environment: The source of `BLESWIFT_LINK` when `--listen` is absent. The default is
    ///     the process environment.
    /// - Throws: ``ParseError`` for an argument that the subcommand does not accept.
    public static func parseCommand(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Command {
        guard let first = arguments.first else { return .serve(try parse(arguments, environment: environment)) }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "-h", "--help":
            return .help
        case "status":
            guard !containsHelp(rest) else { return .help }
            return .status(try parseStatus(rest, environment: environment))
        case "capture":
            guard !containsHelp(rest) else { return .help }
            return .capture(try parseCapture(rest))
        case "install-agent":
            guard !containsHelp(rest) else { return .help }
            return .installAgent(try parse(rest, environment: [:]), arguments: rest)
        case "uninstall-agent":
            guard !containsHelp(rest) else { return .help }
            if let extra = rest.first { throw ParseError.unknownFlag(extra) }
            return .uninstallAgent
        default:
            let options = try parse(arguments, environment: environment)
            return options.showHelp ? .help : .serve(options)
        }
    }

    /// Whether `arguments` contain `-h` or `--help`.
    private static func containsHelp(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "-h" || $0 == "--help" }
    }

    /// Returns the value after the flag at `index`, and moves `index` to it.
    private static func flagValue(after index: inout Int, in arguments: [String]) throws -> String {
        let flag = arguments[index]
        index = arguments.index(after: index)
        guard index < arguments.endIndex else { throw ParseError.missingValue(flag) }
        return arguments[index]
    }

    /// Parses the arguments of the `status` subcommand.
    private static func parseStatus(_ arguments: [String], environment: [String: String]) throws -> StatusOptions {
        var options = StatusOptions(endpoint: LinkEndpoint.fromEnvironment(environment) ?? .default)
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--json":
                options.json = true
            case "--listen":
                let value = try flagValue(after: &index, in: arguments)
                guard let endpoint = LinkEndpoint(string: value) else {
                    throw ParseError.invalidEndpoint(value)
                }
                options.endpoint = endpoint
            default:
                throw ParseError.unknownFlag(argument)
            }
            index = arguments.index(after: index)
        }
        return options
    }

    /// Parses the arguments of the `capture` subcommand.
    private static func parseCapture(_ arguments: [String]) throws -> CaptureOptions {
        var options = CaptureOptions()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--duration":
                let value = try flagValue(after: &index, in: arguments)
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
                    throw ParseError.invalidValue(flag: argument, value: value)
                }
                options.duration = .seconds(seconds)
            case "--name":
                options.names.append(try flagValue(after: &index, in: arguments))
            case "--service":
                let value = try flagValue(after: &index, in: arguments)
                guard WireIdentifierValidation.isValid(value) else {
                    throw ParseError.invalidValue(flag: argument, value: value)
                }
                options.services.append(value)
            case "--all":
                options.all = true
            case "--output":
                options.outputPath = try flagValue(after: &index, in: arguments)
            default:
                throw ParseError.unknownFlag(argument)
            }
            index = arguments.index(after: index)
        }
        return options
    }

    /// The warning to print at startup when `endpoint` is not on the loopback interface, or `nil`
    /// when it is.
    ///
    /// The link has no authentication. A provider bound to a routable address serves any client
    /// that reaches it. If `--passthrough` is on, the Mac's real Bluetooth radio is behind that
    /// client.
    ///
    /// - Parameter endpoint: The endpoint on which the provider will listen.
    /// - Returns: One line to print, or `nil`.
    public static func nonLoopbackWarning(for endpoint: LinkEndpoint) -> String? {
        guard !endpoint.isLoopback else { return nil }
        return "bleswift-provider: warning: listening on a non-loopback interface; the link is unauthenticated"
    }

    /// The usage text for `-h`/`--help` and for a ``ParseError`` report. It lists every
    /// subcommand and its flags.
    public static let usage = """
    Usage: bleswift-provider [options]
           bleswift-provider <command> [options]

    Commands:
      (none)                 Serve the link. This is the default. See Options.
      status                 Print the status of a running provider.
        --listen <host:port>   The provider to ask. Defaults to BLESWIFT_LINK if set,
                                otherwise 127.0.0.1:45541.
        --json                 Print the status as JSON.
                               Exits 69 if no provider answers, 76 if it rejects the request.
      capture                Scan for real devices with this Mac's Bluetooth and write a
                              fixture document for them.
        --duration <seconds>   How long to scan. Defaults to 10.
        --name <text>          Keep devices whose name contains the text. Repeatable.
        --service <uuid>       Keep devices that advertise the service. Repeatable.
        --all                  Capture every listed device. Do not ask.
        --output <path>        Write the document to the path. Defaults to standard output.
      install-agent [options]
                             Install a launch agent that runs the provider at login with the
                              options given. The agent must listen on loopback.
      uninstall-agent        Remove the launch agent.

    Options:
      --listen <host:port>   Where to listen. Defaults to the BLESWIFT_LINK environment
                              variable if set, otherwise 127.0.0.1:45541. The link is
                              unauthenticated and intended for loopback only; a non-loopback
                              host serves any client that can reach the port.
      --fixture <path>       Load a fixture document and host its devices. Repeatable.
      --passthrough          Also expose the host machine's real CoreBluetooth to central-role
                              clients, alongside the virtual devices.
      --json                 Encode outgoing messages as JSON instead of the binary property
                              list default.
      --verbose              Log one line for each link message in each direction.
      -h, --help             Print this help text and exit.

    Environment:
      BLESWIFT_LINK           host:port to listen on, used when --listen is not given.
    """
}
#endif

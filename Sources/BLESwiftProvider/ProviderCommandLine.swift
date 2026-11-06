//
//  ProviderCommandLine.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Foundation

/// The command-line interface for the `bleswift-provider` executable.
///
/// The grammar is small: five flags, and one of them can repeat. Thus ``parse(_:environment:)``
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
        /// Whether the arguments contain `-h`/`--help`. When `true`, parsing stopped at the flag
        /// and the other fields are incomplete.
        public var showHelp: Bool

        /// Creates an `Options` value directly, with the defaults of ``parse(_:environment:)``.
        public init(
            endpoint: LinkEndpoint = .default,
            codec: LinkCodec = .binaryPropertyList,
            passthrough: Bool = false,
            fixturePaths: [String] = [],
            showHelp: Bool = false
        ) {
            self.endpoint = endpoint
            self.codec = codec
            self.passthrough = passthrough
            self.fixturePaths = fixturePaths
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

        public var description: String {
            switch self {
            case .unknownFlag(let flag):
                "unrecognized flag \(flag)"
            case .missingValue(let flag):
                "\(flag) requires a value"
            case .invalidEndpoint(let value):
                "\(value) is not a valid host:port endpoint"
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

    /// The usage text for `-h`/`--help` and for a ``ParseError`` report.
    public static let usage = """
    Usage: bleswift-provider [options]

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
      -h, --help             Print this help text and exit.

    Environment:
      BLESWIFT_LINK           host:port to listen on, used when --listen is not given.
    """
}
#endif

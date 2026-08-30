//
//  ProviderCommandLine.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Foundation

/// The hand-parsed command-line surface for the `bleswift-provider` executable.
///
/// No third-party argument-parsing dependency is used: the grammar is small enough (five
/// flags, one of them repeatable) that ``parse(_:environment:)`` just walks the argument
/// array itself.
public enum ProviderCommandLine {

    /// The parsed result of ``parse(_:environment:)``.
    public struct Options: Sendable, Equatable {
        /// Where the provider listens. Defaults to `--listen`, then `BLESWIFT_LINK`, then
        /// `LinkEndpoint.default`.
        public var endpoint: LinkEndpoint
        /// The codec the provider encodes with. `--json` selects `LinkCodec.json`;
        /// otherwise `LinkCodec.binaryPropertyList`.
        public var codec: LinkCodec
        /// Whether `--passthrough` was given.
        public var passthrough: Bool
        /// The paths passed via `--fixture`, in the order they appeared.
        public var fixturePaths: [String]
        /// Whether `-h`/`--help` was given. When `true`, every other field is unpopulated —
        /// parsing stops as soon as help is seen.
        public var showHelp: Bool

        /// Creates an `Options` value directly. Exposed for callers that want the same
        /// defaults ``parse(_:environment:)`` uses without going through argument parsing.
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

    /// What can go wrong while parsing ``parse(_:environment:)``'s `arguments`.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        /// An argument that isn't one of the recognized flags.
        case unknownFlag(String)
        /// A flag that takes a value appeared with nothing after it.
        case missingValue(String)
        /// `--listen`'s value did not parse as `host:port`.
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
    /// `-h`/`--help` short-circuits: as soon as it is seen, parsing stops and `showHelp` is
    /// `true` on the returned `Options` — nothing after it, valid or not, is inspected.
    ///
    /// - Parameters:
    ///   - arguments: The command-line arguments, not including the executable path.
    ///   - environment: Consulted for `BLESWIFT_LINK` when `--listen` is absent. Defaults to
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

    /// The warning to print at startup when `endpoint` is not on the loopback interface, or
    /// `nil` when it is.
    ///
    /// The link carries no authentication of any kind: a provider bound to a routable address
    /// serves any client that reaches it, with the Mac's real Bluetooth radio behind it when
    /// `--passthrough` is on. That is a deliberate simplification for a loopback development
    /// tool — and worth saying out loud the moment the tool stops being on loopback.
    ///
    /// - Parameter endpoint: The endpoint the provider is about to listen on.
    /// - Returns: One line to print, or `nil`.
    public static func nonLoopbackWarning(for endpoint: LinkEndpoint) -> String? {
        guard !endpoint.isLoopback else { return nil }
        return "bleswift-provider: warning: listening on a non-loopback interface; the link is unauthenticated"
    }

    /// Usage text for `-h`/`--help` and for reporting a ``ParseError``.
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

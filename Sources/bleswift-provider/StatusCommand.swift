//
//  StatusCommand.swift
//  bleswift-provider
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Foundation

/// The `status` subcommand. It asks a running provider for its status and prints it.
enum StatusCommand {

    /// Asks the provider at `options.endpoint` for its status and prints it to standard output.
    ///
    /// - Returns: The exit status. It is `0` on success, `69` (`EX_UNAVAILABLE`) if no provider
    ///   answers, and `76` (`EX_PROTOCOL`) if the provider rejects the request.
    static func run(_ options: ProviderCommandLine.StatusOptions) async -> Int32 {
        let status: ProviderStatus
        do {
            status = try await ProviderStatusClient.fetch(endpoint: options.endpoint)
        } catch let error as ProviderStatusError {
            switch error {
            case .unreachable, .timedOut:
                printError("bleswift-provider: no provider at \(options.endpoint)")
                return 69
            case .rejected, .unexpectedMessage:
                // A provider that closes the connection without a reply gives a reason that
                // already says that it may be older than this tool.
                printError("bleswift-provider: \(error)")
                return 76
            }
        } catch {
            printError("bleswift-provider: \(error)")
            return 69
        }
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(status)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                printError("bleswift-provider: failed to encode the status: \(error)")
                return 70
            }
        } else {
            print(render(status, endpoint: options.endpoint))
        }
        return 0
    }

    /// The text form of `status`. Each session is on a line of its own, in ordinal order.
    static func render(_ status: ProviderStatus, endpoint: LinkEndpoint) -> String {
        var lines = [
            "\(status.providerName) at \(endpoint)",
            "passthrough: \(status.passthrough ? "on" : "off")",
            "fixture devices: \(status.fixtureDeviceCount)",
            "sessions: \(status.sessions.count)",
        ]
        let ordinalWidth = status.sessions.map { String($0.ordinal).count }.max() ?? 1
        let roleWidth = LinkRole.allCases.map(\.rawValue.count).max() ?? 0
        for session in status.sessions {
            let ordinal = String(session.ordinal)
            let paddedOrdinal = String(repeating: " ", count: ordinalWidth - ordinal.count) + ordinal
            let role = session.role.rawValue.padding(toLength: roleWidth, withPad: " ", startingAt: 0)
            lines.append("  \(paddedOrdinal)  \(role)  \(session.clientName)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Writes `line` and a newline to standard error.
func printError(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}
#endif

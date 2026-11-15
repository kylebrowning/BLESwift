//
//  AgentCommand.swift
//  bleswift-provider
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Foundation

/// The `install-agent` and `uninstall-agent` subcommands. They write or remove the launch agent
/// of ``ProviderAgent`` and tell `launchctl` about it.
enum AgentCommand {

    /// The path of the agent's property list file.
    static var propertyListPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(ProviderAgent.label).plist"
    }

    /// The path of the agent's log file.
    static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/bleswift-provider.log"
    }

    /// The `launchctl` domain of the current user's GUI session.
    static var domain: String {
        "gui/\(getuid())"
    }

    /// Writes the agent's property list and loads it with `launchctl`.
    ///
    /// - Parameters:
    ///   - options: The parsed serve options. The function uses them to check the endpoint.
    ///   - arguments: The serve arguments, exactly as given. The agent runs with them.
    /// - Returns: The exit status. It is `0` on success, `64` (`EX_USAGE`) for a non-loopback
    ///   endpoint, and `70` (`EX_SOFTWARE`) if the file cannot be written or
    ///   `launchctl bootstrap` fails.
    static func install(options: ProviderCommandLine.Options, arguments: [String]) -> Int32 {
        if let error = ProviderAgent.endpointError(for: options.endpoint) {
            printError(error)
            return 64
        }
        let executable = ProviderAgent.executablePath(
            argument: CommandLine.arguments[0],
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        if let warning = ProviderAgent.buildDirectoryWarning(for: executable) {
            printError(warning)
        }
        let plist = ProviderAgent.propertyList(executable: executable, arguments: arguments, logPath: logPath)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let url = URL(fileURLWithPath: propertyListPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            printError("bleswift-provider: failed to write \(propertyListPath): \(error)")
            return 70
        }
        // Remove an agent that an earlier install loaded. This fails when no agent is loaded,
        // so ignore its status.
        _ = launchctl(["bootout", "\(domain)/\(ProviderAgent.label)"])
        let bootstrap = launchctl(["bootstrap", domain, propertyListPath])
        guard bootstrap.status == 0 else {
            printError("bleswift-provider: launchctl bootstrap failed: \(bootstrap.standardError)")
            return 70
        }
        print("installed the launch agent at \(propertyListPath)")
        print("the agent writes its log to \(logPath)")
        return 0
    }

    /// Unloads the agent with `launchctl` and removes its property list file.
    ///
    /// - Returns: The exit status, which is always `0`.
    static func uninstall() -> Int32 {
        // This fails when no agent is loaded, so ignore its status.
        _ = launchctl(["bootout", "\(domain)/\(ProviderAgent.label)"])
        print("unloaded the launch agent \(ProviderAgent.label), if it was loaded")
        if FileManager.default.fileExists(atPath: propertyListPath) {
            do {
                try FileManager.default.removeItem(atPath: propertyListPath)
                print("removed \(propertyListPath)")
            } catch {
                printError("bleswift-provider: failed to remove \(propertyListPath): \(error)")
            }
        } else {
            print("no agent file at \(propertyListPath)")
        }
        return 0
    }

    /// Runs `/bin/launchctl` with `arguments` and waits for it to exit.
    ///
    /// - Returns: The exit status and the text that the tool wrote to standard error.
    private static func launchctl(_ arguments: [String]) -> (status: Int32, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }
}
#endif

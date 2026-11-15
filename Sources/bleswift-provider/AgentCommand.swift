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
    ///   - arguments: The serve arguments, as given. The agent runs with them, with each
    ///     `--fixture` path made absolute and with an explicit `--listen`.
    /// - Returns: The exit status. It is `0` on success, `64` (`EX_USAGE`) for a non-loopback
    ///   endpoint, `66` (`EX_NOINPUT`) for a fixture that does not load, and `70` (`EX_SOFTWARE`) if the executable is not found, the file cannot be
    ///   written, or `launchctl bootstrap` fails.
    static func install(options: ProviderCommandLine.Options, arguments: [String]) -> Int32 {
        if let error = ProviderAgent.endpointError(for: options.endpoint) {
            printError(error)
            return 64
        }
        guard let executable = ProviderAgent.executablePath(
            argument: CommandLine.arguments[0],
            currentDirectory: FileManager.default.currentDirectoryPath,
            searchPath: ProcessInfo.processInfo.environment["PATH"]
        ) else {
            printError("bleswift-provider: cannot find the bleswift-provider executable; run install-agent with a full path")
            return 70
        }
        if let warning = ProviderAgent.buildDirectoryWarning(for: executable) {
            printError(warning)
        }
        let currentDirectory = FileManager.default.currentDirectoryPath
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        // Load each fixture now, so that a bad path fails here and not in the unattended agent.
        for path in options.fixturePaths {
            do {
                _ = try FixtureDocument.load(from: URL(fileURLWithPath: path, relativeTo: base).standardized)
            } catch {
                printError("bleswift-provider: failed to load fixture \(path): \(error)")
                return 66
            }
        }
        let agentArguments = ProviderAgent.agentArguments(
            arguments,
            endpoint: options.endpoint,
            currentDirectory: currentDirectory
        )
        let plist = ProviderAgent.propertyList(executable: executable, arguments: agentArguments, logPath: logPath)
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
            // Remove the new plist. Otherwise launchd loads an agent that did not start at the
            // next login, after the command reported a failure.
            try? FileManager.default.removeItem(atPath: propertyListPath)
            printError("bleswift-provider: removed \(propertyListPath)")
            return 70
        }
        print("installed the launch agent at \(propertyListPath)")
        print("the agent writes its log to \(logPath)")
        return 0
    }

    /// Unloads the agent with `launchctl` and removes its property list file.
    ///
    /// - Returns: The exit status. It is `0` on success, and `74` (`EX_IOERR`) if the file
    ///   cannot be removed.
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
                return 74
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

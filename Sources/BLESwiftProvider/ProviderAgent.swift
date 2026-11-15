//
//  ProviderAgent.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Foundation

/// The launch agent that `bleswift-provider install-agent` installs. The agent runs the provider
/// at login and starts it again if it exits.
///
/// This type only renders and checks. It does not call `launchctl`, so a test can use it.
public enum ProviderAgent {

    /// The `Label` of the agent, and the base name of its property list file.
    public static let label = "com.kylebrowning.bleswift-provider"

    /// The property list of the agent.
    ///
    /// - Parameters:
    ///   - executable: The absolute path of the `bleswift-provider` executable.
    ///   - arguments: The serve arguments, exactly as the user gave them.
    ///   - logPath: The absolute path of the file for standard output and standard error.
    /// - Returns: The keys for `PropertyListSerialization`.
    package static func propertyList(executable: String, arguments: [String], logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            // Start the provider again only after a failure. A provider that exits with
            // status 0 stays stopped.
            "KeepAlive": ["SuccessfulExit": false],
            // Wait at least 30 seconds between two starts, so a provider that fails at once does
            // not start in a tight loop.
            "ThrottleInterval": 30,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    /// `arguments` with each `--fixture` path made absolute against `currentDirectory`. Every
    /// other argument stays as given, in order.
    ///
    /// The agent does not run in the current directory of `install-agent`, so a relative path
    /// would not resolve.
    ///
    /// - Parameters:
    ///   - arguments: Serve arguments that ``ProviderCommandLine/parse(_:environment:)`` accepts.
    ///   - currentDirectory: The current directory of the process.
    /// - Returns: The arguments for the agent.
    package static func absoluteFixtureArguments(_ arguments: [String], currentDirectory: String) -> [String] {
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            result.append(argument)
            // A value-taking flag consumes the next argument. Only the value of `--fixture`
            // changes.
            if argument == "--fixture" || argument == "--listen" {
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { break }
                let value = arguments[index]
                result.append(argument == "--fixture" ? URL(fileURLWithPath: value, relativeTo: base).standardized.path : value)
            }
            index = arguments.index(after: index)
        }
        return result
    }

    /// The error to print when the agent would listen on `endpoint`, or `nil` if `endpoint` is
    /// on loopback.
    ///
    /// The agent runs unattended. Nobody sees the warning for a non-loopback listener, so the
    /// agent must listen on loopback.
    ///
    /// - Parameter endpoint: The endpoint on which the agent would listen.
    /// - Returns: One line to print, or `nil`.
    package static func endpointError(for endpoint: LinkEndpoint) -> String? {
        guard !endpoint.isLoopback else { return nil }
        return "bleswift-provider: the agent runs unattended, so it must listen on loopback, not \(endpoint)"
    }

    /// The absolute path of the executable that `argument` names, or `nil` if no file matches.
    ///
    /// - If `argument` contains a `/`, the function makes it absolute against
    ///   `currentDirectory`.
    /// - If `argument` is a bare name, the function searches the directories of `searchPath` in
    ///   order. It returns the first executable file with that name. A shell runs a command from
    ///   `PATH` with a bare `argv[0]`.
    ///
    /// The function does not resolve symbolic links. Thus the agent keeps a Homebrew link such
    /// as `/opt/homebrew/bin/bleswift-provider`, and a Homebrew upgrade does not break it.
    ///
    /// - Parameters:
    ///   - argument: The first command-line argument, `argv[0]`.
    ///   - currentDirectory: The current directory of the process.
    ///   - searchPath: The value of `PATH`, with directories separated by `:`.
    /// - Returns: The absolute path, or `nil`.
    package static func executablePath(argument: String, currentDirectory: String, searchPath: String?) -> String? {
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        guard !argument.contains("/") else {
            return URL(fileURLWithPath: argument, relativeTo: base).standardized.path
        }
        for directory in (searchPath ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let folder = URL(fileURLWithPath: String(directory), isDirectory: true, relativeTo: base)
            let candidate = folder.appendingPathComponent(argument).standardized.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// The warning to print when `executablePath` is inside a build directory, or `nil`.
    ///
    /// - Parameter executablePath: The absolute path of the executable.
    /// - Returns: One line to print, or `nil`.
    package static func buildDirectoryWarning(for executablePath: String) -> String? {
        guard executablePath.contains("/.build/") else { return nil }
        return "bleswift-provider: warning: the agent runs \(executablePath). "
            + "The agent will break when you clean the build directory."
    }
}
#endif

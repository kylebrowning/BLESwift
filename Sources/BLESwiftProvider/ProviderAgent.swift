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
    public static func propertyList(executable: String, arguments: [String], logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable] + arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    /// The error to print when the agent would listen on `endpoint`, or `nil` if `endpoint` is
    /// on loopback.
    ///
    /// The agent runs unattended. Nobody sees the warning for a non-loopback listener, so the
    /// agent must listen on loopback.
    ///
    /// - Parameter endpoint: The endpoint on which the agent would listen.
    /// - Returns: One line to print, or `nil`.
    public static func endpointError(for endpoint: LinkEndpoint) -> String? {
        guard !endpoint.isLoopback else { return nil }
        return "bleswift-provider: the agent runs unattended, so it must listen on loopback, not \(endpoint)"
    }

    /// The absolute path of the executable that `argument` names.
    ///
    /// The function makes a relative path absolute against `currentDirectory`. It does not
    /// resolve symbolic links. Thus the agent keeps a Homebrew link such as
    /// `/opt/homebrew/bin/bleswift-provider`, and a Homebrew upgrade does not break it.
    ///
    /// - Parameters:
    ///   - argument: The first command-line argument, `argv[0]`.
    ///   - currentDirectory: The current directory of the process.
    /// - Returns: The absolute path.
    public static func executablePath(argument: String, currentDirectory: String) -> String {
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        return URL(fileURLWithPath: argument, relativeTo: base).standardized.path
    }

    /// The warning to print when `executablePath` is inside a build directory, or `nil`.
    ///
    /// - Parameter executablePath: The absolute path of the executable.
    /// - Returns: One line to print, or `nil`.
    public static func buildDirectoryWarning(for executablePath: String) -> String? {
        guard executablePath.contains("/.build/") else { return nil }
        return "bleswift-provider: warning: the agent runs \(executablePath). "
            + "The agent will break when you clean the build directory."
    }
}
#endif

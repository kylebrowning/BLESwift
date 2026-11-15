//
//  CaptureCommand.swift
//  bleswift-provider
//

#if os(macOS)
import BLESwift
import BLESwiftLink
import BLESwiftProvider
import Foundation

/// The `capture` subcommand. It scans with the Mac's real Bluetooth, lets the user select
/// devices, and writes a fixture document for them.
enum CaptureCommand {

    /// The time limit for the radio to become powered on.
    static let powerOnTimeout: Duration = .seconds(5)

    /// Runs the capture.
    ///
    /// - Returns: The exit status:
    ///   - `0` on success, or when the user selects nothing.
    ///   - `1` if no device matches.
    ///   - `64` (`EX_USAGE`) for a bad selection, or for a non-interactive run without
    ///     `--all`, `--name`, or `--service`.
    ///   - `69` (`EX_UNAVAILABLE`) if Bluetooth is not powered on.
    ///   - `73` (`EX_CANTCREAT`) if the output cannot be written.
    static func run(_ options: ProviderCommandLine.CaptureOptions) async -> Int32 {
        let central = Central()
        let state = await waitForPoweredOn(central)
        guard state == .poweredOn else {
            printError("bleswift-provider: Bluetooth is not powered on (state: \(state))")
            return 69
        }
        let capture = FixtureCapture(central: central)
        printError("scanning for \(options.duration)")
        let candidates: [FixtureCapture.Candidate]
        do {
            candidates = try await capture.scan(for: options.duration, names: options.names, services: options.services)
        } catch {
            printError("bleswift-provider: the scan failed: \(error)")
            return 69
        }
        guard !candidates.isEmpty else {
            printError("bleswift-provider: no matching devices")
            return 1
        }
        printTable(candidates)

        let selected: [FixtureCapture.Candidate]
        if options.all || !options.names.isEmpty || !options.services.isEmpty {
            selected = candidates
        } else if isatty(STDIN_FILENO) == 1 {
            FileHandle.standardError.write(Data("Devices to capture (for example 1,3 or all): ".utf8))
            let line = readLine() ?? ""
            do {
                selected = try FixtureCapture.parseSelection(line, count: candidates.count).map { candidates[$0] }
            } catch {
                printError("bleswift-provider: \(error)")
                return 64
            }
            guard !selected.isEmpty else { return 0 }
        } else {
            printError("bleswift-provider: in a non-interactive run, pass --all, --name, or --service")
            return 64
        }

        let document = await capture.inspect(selected) { warning in
            printError("bleswift-provider: warning: \(warning)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            var data = try encoder.encode(document)
            data.append(contentsOf: Array("\n".utf8))
            if let path = options.outputPath {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                printError("wrote \(document.devices.count) device(s) to \(path)")
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            printError("bleswift-provider: failed to write the fixture document: \(error)")
            return 73
        }
        return 0
    }

    /// Waits up to ``powerOnTimeout`` for `central` to become powered on.
    ///
    /// - Returns: The last state that the central reported.
    private static func waitForPoweredOn(_ central: Central) async -> CentralState {
        let deadline = ContinuousClock.now + powerOnTimeout
        while central.state != .poweredOn, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return central.state
    }

    /// Prints the numbered table of `candidates` to standard error.
    private static func printTable(_ candidates: [FixtureCapture.Candidate]) {
        for (index, candidate) in candidates.enumerated() {
            let services = (candidate.advertisement.serviceUUIDs ?? []).map(\.uuidString)
            let columns = [
                String(format: "%3d", index + 1),
                String(format: "%4d dBm", candidate.rssi),
                candidate.name ?? "(unnamed)",
                services.isEmpty ? "-" : services.joined(separator: ","),
                candidate.isConnectable ? "connectable" : "not connectable",
            ]
            printError(columns.joined(separator: "  "))
        }
    }
}
#endif

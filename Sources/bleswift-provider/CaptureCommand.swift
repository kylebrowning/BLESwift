//
//  CaptureCommand.swift
//  bleswift-provider
//

#if os(macOS)
import BLESwiftProvider

/// The `capture` subcommand.
enum CaptureCommand {
    static func run(_ options: ProviderCommandLine.CaptureOptions) async -> Int32 {
        printError("bleswift-provider: capture is not available yet")
        return 70
    }
}
#endif

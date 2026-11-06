//
//  main.swift
//  bleswift-provider
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Dispatch
import Foundation

// Line-buffer stdout, so the "listening on …" line reaches a redirected log (a pipe or a file)
// immediately. Scripts wait on that line to know that the provider is ready.
setlinebuf(stdout)

let arguments = Array(CommandLine.arguments.dropFirst())

let options: ProviderCommandLine.Options
do {
    options = try ProviderCommandLine.parse(arguments)
} catch {
    FileHandle.standardError.write(Data("bleswift-provider: \(error)\n\n\(ProviderCommandLine.usage)\n".utf8))
    exit(64)
}

if options.showHelp {
    print(ProviderCommandLine.usage)
    exit(0)
}

var configuration = ProviderConfiguration()
configuration.endpoint = options.endpoint
configuration.codec = options.codec
configuration.passthrough = options.passthrough
configuration.log = { print($0) }

// If a fixture cannot be read or decoded, print the underlying error and exit with `66`
// (`EX_NOINPUT`). Decoding validates every UUID string, so a typo such as `"zzzz"` arrives here
// as a `DecodingError` that names its key and does not trap inside `ServiceIdentifier`.
for path in options.fixturePaths {
    do {
        let document = try FixtureDocument.load(from: URL(fileURLWithPath: path))
        configuration.fixtures.append(contentsOf: document.devices)
    } catch {
        FileHandle.standardError.write(Data("bleswift-provider: failed to load fixture \(path): \(error)\n".utf8))
        exit(66)
    }
}

// The link does not authenticate any client. If the listener is not on loopback, print one
// warning line. Such a listener gives the Mac's radio to anything that can reach the port.
if let warning = ProviderCommandLine.nonLoopbackWarning(for: options.endpoint) {
    FileHandle.standardError.write(Data("\(warning)\n".utf8))
}

let provider = Provider(configuration: configuration)

Task {
    do {
        try await provider.start()
        // Print the bound port, not the requested port: `--listen host:0` asks the system to
        // select one, and scripts must be able to dial the port in the line.
        let bound = LinkEndpoint(host: options.endpoint.host, port: await provider.port)
        print(
            "bleswift-provider listening on \(bound) "
                + "(passthrough: \(options.passthrough ? "on" : "off"), "
                + "fixtures: \(configuration.fixtures.count) device(s))"
        )
    } catch let error as ProviderFixtureError {
        // A fixture that the provider cannot host is a bad input, not a failed bind. Exit with
        // `66` (`EX_NOINPUT`), as for an unreadable fixture.
        FileHandle.standardError.write(Data("bleswift-provider: \(error)\n".utf8))
        exit(66)
    } catch {
        FileHandle.standardError.write(Data("bleswift-provider: failed to start: \(error)\n".utf8))
        exit(70)
    }
}

// SIGINT is for Ctrl-C in a terminal. SIGTERM is for a plain `kill` from a script. Both run
// `provider.stop()`, so the provider closes each client's link before the process ends.
let signalSources = [SIGINT, SIGTERM].map { signal -> DispatchSourceSignal in
    Foundation.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler {
        Task {
            await provider.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
_ = signalSources

RunLoop.main.run()
#else
import Foundation

print("bleswift-provider runs on macOS only")
exit(1)
#endif

//
//  main.swift
//  bleswift-provider
//

#if os(macOS)
import BLESwiftLink
import BLESwiftProvider
import Dispatch
import Foundation

// Line-buffer stdout so the "listening on …" line reaches a redirected log
// (a pipe or file) immediately; scripts wait on that line for readiness.
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

for path in options.fixturePaths {
    do {
        let document = try FixtureDocument.load(from: URL(fileURLWithPath: path))
        configuration.fixtures.append(contentsOf: document.devices)
    } catch {
        FileHandle.standardError.write(Data("bleswift-provider: failed to load fixture \(path): \(error)\n".utf8))
        exit(66)
    }
}

let provider = Provider(configuration: configuration)

Task {
    do {
        try await provider.start()
        // The bound port, not the requested one: `--listen host:0` asks the system to pick,
        // and the line scripts wait on has to name the port they can actually dial.
        let bound = LinkEndpoint(host: options.endpoint.host, port: await provider.port)
        print(
            "bleswift-provider listening on \(bound) "
                + "(passthrough: \(options.passthrough ? "on" : "off"), "
                + "fixtures: \(configuration.fixtures.count) device(s))"
        )
    } catch {
        FileHandle.standardError.write(Data("bleswift-provider: failed to start: \(error)\n".utf8))
        exit(70)
    }
}

signal(SIGINT, SIG_IGN)
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    Task {
        await provider.stop()
        exit(0)
    }
}
signalSource.resume()

RunLoop.main.run()
#else
import Foundation

print("bleswift-provider runs on macOS only")
exit(1)
#endif

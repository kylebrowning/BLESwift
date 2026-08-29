//
//  ProviderConfiguration.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch

/// Everything a ``Provider`` needs to know before it binds a port: where to listen, how to
/// encode, which fixture devices to host, and whether to put the host's own CoreBluetooth
/// behind the same link.
///
/// Every field has a default, so the common case is one mutation:
///
/// ```swift
/// var configuration = ProviderConfiguration()
/// configuration.fixtures = try FixtureDocument.load(from: url).devices
/// let provider = Provider(configuration: configuration)
/// try await provider.start()
/// ```
public struct ProviderConfiguration: Sendable {

    /// Where the provider listens. Defaults to `LinkEndpoint.default`; use
    /// port `0` to have the system assign a free port and read ``Provider/port`` afterwards.
    public var endpoint: LinkEndpoint = .default

    /// The codec the provider encodes its outgoing messages with. Each frame names its own
    /// codec, so a client may answer in another one.
    public var codec: LinkCodec = .binaryPropertyList

    /// Whether a central-role session also sees the host machine's real CoreBluetooth
    /// peripherals, alongside the virtual ones.
    public var passthrough: Bool = false

    /// The fixture devices ``Provider/start()`` registers on ``Provider/radio``.
    public var fixtures: [FixtureDevice] = []

    /// The name the provider reports in its `ServerHello`, for client-side logging.
    public var providerName: String = "bleswift-provider"

    /// Receives one line per notable provider event — sessions opening and closing, refused
    /// handshakes, requests naming an unknown peripheral. `nil` discards them.
    public var log: (@Sendable (String) -> Void)?

    /// Test/consumer hook: replaces the real CoreBluetooth central backend used when
    /// ``passthrough`` is true. The factory is called once per central-role session, on that
    /// session's own serial queue, and must return a backend confined to that queue.
    public var centralBackendFactory: (@Sendable (DispatchSerialQueue) -> any CentralManaging)?

    /// Test/consumer hook: the peripheral-manager counterpart of
    /// ``centralBackendFactory``. The factory is called once per peripheral-role session, on
    /// that session's own serial queue, and must return a backend confined to that queue.
    public var peripheralManagerBackendFactory: (@Sendable (DispatchSerialQueue) -> any PeripheralManaging)?

    /// Test hook: how many peripheral remotes each central-role session keeps. Deliberately
    /// not `public` — a client cannot see this table, and the only reason to shrink it is a
    /// test that would otherwise have to connect a thousand peripherals to force an eviction.
    var maximumRemotesPerCentralSession: Int = CentralSession.defaultMaximumRemotes

    /// Creates a configuration with every field at its default.
    public init() {}
}
#endif

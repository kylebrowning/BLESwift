//
//  ProviderConfiguration.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch

/// The settings that a ``Provider`` needs before it binds a port. They set where to listen,
/// how to encode, which fixture devices to host, and whether to put the host's CoreBluetooth
/// behind the same link.
///
/// Every field has a default, so the common case needs one change:
///
/// ```swift
/// var configuration = ProviderConfiguration()
/// configuration.fixtures = try FixtureDocument.load(from: url).devices
/// let provider = Provider(configuration: configuration)
/// try await provider.start()
/// ```
public struct ProviderConfiguration: Sendable {

    /// Where the provider listens. The default is `LinkEndpoint.default`. For a system-assigned
    /// free port, use port `0` and read ``Provider/port``.
    public var endpoint: LinkEndpoint = .default

    /// The codec with which the provider encodes its outgoing messages. Each frame names its own
    /// codec, so a client can answer with a different codec.
    public var codec: LinkCodec = .binaryPropertyList

    /// Whether a central-role session also sees the host machine's real CoreBluetooth
    /// peripherals, in addition to the virtual peripherals.
    public var passthrough: Bool = false

    /// The fixture devices ``Provider/start()`` registers on ``Provider/radio``.
    public var fixtures: [FixtureDevice] = []

    /// The name that the provider reports in its `ServerHello`. The client uses it for logs.
    public var providerName: String = "bleswift-provider"

    /// The time in which an accepted connection must send a valid `ClientHello`. After this
    /// time, the provider cancels and releases the connection.
    ///
    /// Without a timeout, a client that opens a socket and sends nothing would hold an entry for
    /// as long as the provider runs. Enough such clients would fill ``maximumPendingConnections``
    /// and block every real client. Ten seconds is much longer than a loopback handshake and
    /// short enough to limit a stuck or hostile peer.
    public var handshakeTimeout: Duration = .seconds(10)

    /// The number of accepted connections that can wait for a handshake at the same time. The
    /// provider cancels any connection above this number immediately.
    ///
    /// Only unclaimed connections count. A completed handshake gives its connection to a session
    /// and frees the slot. Sixty-four is much more than the few simulators that a provider serves
    /// in practice, so only a misbehaving peer reaches it.
    public var maximumPendingConnections: Int = 64

    /// Receives one line for each notable provider event, such as a session that opens or
    /// closes, a refused handshake, or a request that names an unknown peripheral. If the value
    /// is `nil`, the provider discards the lines.
    public var log: (@Sendable (String) -> Void)?

    /// A hook for tests and consumers. It replaces the real CoreBluetooth central backend that
    /// the provider uses when ``passthrough`` is true. The provider calls the factory once for
    /// each central-role session, with that session's serial queue. The factory must return a
    /// backend confined to that queue.
    public var centralBackendFactory: (@Sendable (DispatchQueue) -> any CentralManaging)?

    /// A hook for tests and consumers. It is the peripheral-manager version of
    /// ``centralBackendFactory``. The provider calls the factory once for each peripheral-role
    /// session, with that session's serial queue. The factory must return a backend confined to
    /// that queue.
    public var peripheralManagerBackendFactory: (@Sendable (DispatchQueue) -> any PeripheralManaging)?

    /// A hook for tests. It sets the number of peripheral remotes that each central-role
    /// session keeps. It is not `public` on purpose, because only a test needs a smaller value.
    /// Without it, a test must connect a thousand peripherals to force an eviction.
    var maximumRemotesPerCentralSession: Int = CentralSession.defaultMaximumRemotes

    /// Creates a configuration with the default value in every field.
    public init() {}
}
#endif

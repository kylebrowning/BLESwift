//
//  BackendRegistry.swift
//  BLESwiftCore
//

import Dispatch
import BLESwiftCompat17

/// A process-wide override point for the backends that `Central()` and `PeripheralHost()` create by
/// default.
///
/// Both factories are `nil` until some code registers one. After that, the default initializers
/// (`Central(configuration:)` and `PeripheralHost(configuration:)`) build their backend from the
/// factory, not from CoreBluetooth. The `BLESwiftSimulatorLink` module uses this to route an iOS
/// Simulator app's Bluetooth traffic to a provider on the host. Nothing in `BLESwiftCore` or
/// `BLESwift` knows that this module exists.
///
/// The explicit `init(backend:queue:...)` initializers ignore the registry. A backend that you pass
/// directly always wins.
public enum BackendRegistry {

    /// Builds a `CentralManaging` backend confined to the given `DispatchQueue`. The queue is
    /// always serial.
    public typealias CentralFactory = @Sendable (DispatchQueue) -> any CentralManaging

    /// Builds a `PeripheralManaging` backend confined to the given `DispatchQueue`. The queue is
    /// always serial.
    public typealias PeripheralManagerFactory = @Sendable (DispatchQueue) -> any PeripheralManaging

    /// The factories live in a struct and are never the `Mutex`'s `Value` directly (#53).
    /// `withLock` passes its `Value` as `inout`. For a function-type `Value`, the compiler writes
    /// back a reabstracted copy, even on a read (swiftlang/swift#91348). Each `get` would then nest
    /// the stored factory two thunks deeper, until a call overflowed the stack.
    private struct Factories: Sendable {
        var central: CentralFactory?
        var peripheralManager: PeripheralManagerFactory?
    }
    private static let box = Mutex(Factories())

    /// The factory that `Central(configuration:)` reads, or `nil` to use CoreBluetooth.
    public static var centralFactory: CentralFactory? {
        get { box.withLock { $0.central } }
        set { box.withLock { $0.central = newValue } }
    }

    /// The factory that `PeripheralHost(configuration:)` reads, or `nil` to use CoreBluetooth.
    public static var peripheralManagerFactory: PeripheralManagerFactory? {
        get { box.withLock { $0.peripheralManager } }
        set { box.withLock { $0.peripheralManager = newValue } }
    }

    /// Replaces both factories atomically, in one lock acquisition.
    ///
    /// If you set the two properties one at a time, a `Central()` or `PeripheralHost()` that
    /// another thread builds between the two writes could get mismatched backends: one from the
    /// new central factory and one from the previous peripheral-manager factory.
    ///
    /// An installer sets or clears both factories through this function, from inside its own state
    /// lock. `VirtualRadio.install(_:)` and `SimulatorLink.install(endpoint:clientName:codec:)` are
    /// installers. The registry and the installer's record then change together.
    ///
    /// The lock order is always the installer's state lock first and then this registry's lock. The
    /// registry never takes an installer's lock, and it calls nothing while it holds its own.
    ///
    /// - Parameters:
    ///   - central: The factory that `Central(configuration:)` reads from now on, or `nil` for
    ///     CoreBluetooth.
    ///   - peripheralManager: The factory that `PeripheralHost(configuration:)` reads from now on,
    ///     or `nil` for CoreBluetooth.
    public static func setFactories(central: CentralFactory?, peripheralManager: PeripheralManagerFactory?) {
        box.withLock {
            $0.central = central
            $0.peripheralManager = peripheralManager
        }
    }
}

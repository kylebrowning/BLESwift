//
//  BackendRegistry.swift
//  BLESwiftCore
//

import Dispatch
import BLESwiftCompat17

/// A process-wide override point for the backends `Central()` and `PeripheralHost()`
/// construct by default.
///
/// Both factories are `nil` unless something registers one — in which case the default
/// initializers (`Central(configuration:)` / `PeripheralHost(configuration:)`) build their
/// backend from the factory instead of CoreBluetooth. The `BLESwiftSimulatorLink` module
/// uses this to route an app's Bluetooth traffic to a host-side provider from the iOS
/// Simulator; nothing in `BLESwiftCore` or `BLESwift` knows that module exists.
///
/// The explicit `init(backend:queue:...)` initializers ignore the registry — a backend
/// passed directly always wins.
public enum BackendRegistry {

    /// Builds a `CentralManaging` backend confined to the given `DispatchQueue`, which is
    /// always serial (`DispatchQueue(label:)` is).
    public typealias CentralFactory = @Sendable (DispatchQueue) -> any CentralManaging

    /// Builds a `PeripheralManaging` backend confined to the given `DispatchQueue`, which is
    /// always serial (`DispatchQueue(label:)` is).
    public typealias PeripheralManagerFactory = @Sendable (DispatchQueue) -> any PeripheralManaging

    /// The factories live in a struct, never as the `Mutex`'s `Value` directly (#53):
    /// `withLock` passes its `Value` `inout`, and for a function-typed `Value` the compiler
    /// writes back a reabstracted copy even on a read (swiftlang/swift#91348), so every `get`
    /// would nest the stored factory two thunks deeper until calling it overflowed the stack.
    private struct Factories: Sendable {
        var central: CentralFactory?
        var peripheralManager: PeripheralManagerFactory?
    }
    private static let box = Mutex(Factories())

    /// The factory `Central(configuration:)` consults, or `nil` to use CoreBluetooth.
    public static var centralFactory: CentralFactory? {
        get { box.withLock { $0.central } }
        set { box.withLock { $0.central = newValue } }
    }

    /// The factory `PeripheralHost(configuration:)` consults, or `nil` to use CoreBluetooth.
    public static var peripheralManagerFactory: PeripheralManagerFactory? {
        get { box.withLock { $0.peripheralManager } }
        set { box.withLock { $0.peripheralManager = newValue } }
    }
}

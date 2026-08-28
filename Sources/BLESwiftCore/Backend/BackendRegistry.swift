//
//  BackendRegistry.swift
//  BLESwiftCore
//

import Dispatch
import Synchronization

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

    /// Builds a `CentralManaging` backend confined to the given `DispatchSerialQueue`.
    public typealias CentralFactory = @Sendable (DispatchSerialQueue) -> any CentralManaging

    /// Builds a `PeripheralManaging` backend confined to the given `DispatchSerialQueue`.
    public typealias PeripheralManagerFactory = @Sendable (DispatchSerialQueue) -> any PeripheralManaging

    private static let centralBox = Mutex<CentralFactory?>(nil)
    private static let peripheralManagerBox = Mutex<PeripheralManagerFactory?>(nil)

    /// The factory `Central(configuration:)` consults, or `nil` to use CoreBluetooth.
    public static var centralFactory: CentralFactory? {
        get { centralBox.withLock { $0 } }
        set { centralBox.withLock { $0 = newValue } }
    }

    /// The factory `PeripheralHost(configuration:)` consults, or `nil` to use CoreBluetooth.
    public static var peripheralManagerFactory: PeripheralManagerFactory? {
        get { peripheralManagerBox.withLock { $0 } }
        set { peripheralManagerBox.withLock { $0 = newValue } }
    }
}

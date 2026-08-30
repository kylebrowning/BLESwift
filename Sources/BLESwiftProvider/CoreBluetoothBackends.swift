//
//  CoreBluetoothBackends.swift
//  BLESwiftProvider
//

#if os(macOS)
// The one file in this module that imports CoreBluetooth. `BLESwift` supplies the
// `CBCentralManager: CentralManaging` / `CBPeripheralManager: PeripheralManaging`
// conformances these factories return, and re-exports `BLESwiftCore` for the protocols
// themselves.
import BLESwift
import BLESwiftCore
import CoreBluetooth
import Dispatch

/// The host machine's own CoreBluetooth, as `CentralManaging` and
/// `PeripheralManaging` — the "real" half a passthrough ``Provider``
/// composes with its ``VirtualRadio``.
///
/// A ``Provider`` whose ``ProviderConfiguration/passthrough`` is set calls these for every
/// session that has no injected
/// ``ProviderConfiguration/centralBackendFactory``/``ProviderConfiguration/peripheralManagerBackendFactory``,
/// and hands the result to ``CompositeCentral``/``CompositePeripheralManager`` alongside the
/// virtual backend. Call them directly only to build the same composition by hand.
///
/// - Important: Both factories **must be called on `queue`**, and the returned backend is
///   confined to it: it is the delivery queue CoreBluetooth was constructed with, so every
///   subsequent call and every delegate callback belongs to that queue. The composites
///   require exactly this — every child on the one shared queue.
///
/// - Note: Neither factory installs a delegate. `BLESwift`'s conformances create and retain
///   their delegate proxy the first time `eventHandler` is *set*, so
///   `CBCentralManager(delegate: nil, queue:)` followed by an `eventHandler` assignment is
///   fully wired. Assign it on `queue` synchronously, before the queue is allowed to yield,
///   or the initial `didUpdateState` fires against no handler and is lost.
public enum CoreBluetoothBackends {

    /// A real `CBCentralManager` confined to `queue`, as a `CentralManaging`.
    ///
    /// The system power alert is suppressed (`CBCentralManagerOptionShowPowerAlertKey`):
    /// a provider is a background tool, and a modal "Turn on Bluetooth" panel raised by a
    /// simulator's scan would be a surprise with no one to answer it. A powered-off radio
    /// simply reports `CentralState.poweredOff`, and the composite carries on
    /// with the virtual half.
    ///
    /// - Parameter queue: The serial queue CoreBluetooth delivers on and the returned
    ///   backend is confined to. Must be the queue this call is made from.
    /// - Returns: The manager, with no delegate installed yet — set `eventHandler` on
    ///   `queue` before yielding it.
    public static func makeCentral(queue: DispatchSerialQueue) -> any CentralManaging {
        CBCentralManager(
            delegate: nil,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    /// A real `CBPeripheralManager` confined to `queue`, as a
    /// `PeripheralManaging`.
    ///
    /// The system power alert is suppressed (`CBPeripheralManagerOptionShowPowerAlertKey`),
    /// for the reason ``makeCentral(queue:)`` gives: a host session that starts advertising
    /// with Bluetooth off would otherwise raise a modal "Turn on Bluetooth" panel on a
    /// background tool with no one to answer it. The composite carries on with the virtual
    /// half, and picks the Mac's radio up when the user turns it on.
    ///
    /// - Parameter queue: The serial queue CoreBluetooth delivers on and the returned
    ///   backend is confined to. Must be the queue this call is made from.
    /// - Returns: The manager, with no delegate installed yet — set `eventHandler` on
    ///   `queue` before yielding it.
    public static func makePeripheralManager(queue: DispatchSerialQueue) -> any PeripheralManaging {
        CBPeripheralManager(
            delegate: nil,
            queue: queue,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }
}
#endif

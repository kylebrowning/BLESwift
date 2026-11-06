//
//  CoreBluetoothBackends.swift
//  BLESwiftProvider
//

#if os(macOS)
// This is the one file in this module that imports CoreBluetooth. `BLESwift` supplies the
// `CBCentralManager: CentralManaging` and `CBPeripheralManager: PeripheralManaging`
// conformances that these factories return, and re-exports `BLESwiftCore` for the protocols.
import BLESwift
import BLESwiftCore
import CoreBluetooth
import Dispatch

/// The host machine's CoreBluetooth, as `CentralManaging` and `PeripheralManaging`. A
/// passthrough ``Provider`` combines this real half with its ``VirtualRadio``.
///
/// A ``Provider`` that sets ``ProviderConfiguration/passthrough`` calls these factories for
/// each session that has no injected
/// ``ProviderConfiguration/centralBackendFactory``/``ProviderConfiguration/peripheralManagerBackendFactory``.
/// It gives the result to ``CompositeCentral``/``CompositePeripheralManager`` together with the
/// virtual backend. Call the factories directly only to build the same composition by hand.
///
/// - Important: Call both factories **on `queue`**. The returned backend is confined to
///   `queue`, the delivery queue with which CoreBluetooth was constructed, so every later call
///   and delegate callback belongs to that queue. The composites require all children to use
///   the one shared queue.
///
/// - Note: Neither factory installs a delegate. The `BLESwift` conformances create and retain
///   their delegate proxy when `eventHandler` is first *set*, so
///   `CBCentralManager(delegate: nil, queue:)` followed by an `eventHandler` assignment is
///   fully wired. Assign `eventHandler` on `queue` synchronously, before the queue can yield.
///   Otherwise the initial `didUpdateState` fires with no handler and is lost.
public enum CoreBluetoothBackends {

    /// A real `CBCentralManager` confined to `queue`, as a `CentralManaging`.
    ///
    /// This method suppresses the system power alert (`CBCentralManagerOptionShowPowerAlertKey`).
    /// A provider is a background tool, and no one is there to answer a modal "Turn on
    /// Bluetooth" panel. A radio that is off reports `CentralState.poweredOff`, and the
    /// composite continues with the virtual half.
    ///
    /// - Parameter queue: The serial queue on which CoreBluetooth delivers and to which the
    ///   returned backend is confined. Call this method from that queue.
    /// - Returns: The manager. It has no delegate yet. Set `eventHandler` on `queue` before
    ///   you yield the manager.
    public static func makeCentral(queue: DispatchQueue) -> any CentralManaging {
        CBCentralManager(
            delegate: nil,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    /// A real `CBPeripheralManager` confined to `queue`, as a
    /// `PeripheralManaging`.
    ///
    /// This method suppresses the system power alert
    /// (`CBPeripheralManagerOptionShowPowerAlertKey`), for the reason that
    /// ``makeCentral(queue:)`` gives. A host session can start advertising with Bluetooth off.
    /// The composite continues with the virtual half and uses the Mac's radio when the user
    /// turns it on.
    ///
    /// - Parameter queue: The serial queue on which CoreBluetooth delivers and to which the
    ///   returned backend is confined. Call this method from that queue.
    /// - Returns: The manager. It has no delegate yet. Set `eventHandler` on `queue` before
    ///   you yield the manager.
    public static func makePeripheralManager(queue: DispatchQueue) -> any PeripheralManaging {
        CBPeripheralManager(
            delegate: nil,
            queue: queue,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
    }
}
#endif

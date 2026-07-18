//
//  PeripheralDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import Synchronization

/// Bridges real `CBPeripheralDelegate` callbacks into a `PeripheralEvent` handler closure
/// — the `PeripheralRemote` conformance's implementation of `eventHandler` for
/// `CBPeripheral`.
///
/// One instance per `CBPeripheral`, created lazily and retained via an associated object
/// by `CBPeripheral`'s `eventHandler` setter (see `CBPeripheral+PeripheralRemote.swift`) —
/// `CBPeripheral.delegate` is `weak`, so something must keep this instance alive for as
/// long as its peripheral is expected to deliver events.
///
/// Split out of the combined `CentralDelegateProxy` this phase: previously one proxy
/// handled both `CBCentralManagerDelegate` and `CBPeripheralDelegate`, using a `weak var
/// central: Central?` back-reference. Per-peripheral event routing is now a plain closure
/// `Central` supplies at each attach site (capturing the `PeripheralIdentifier` it already
/// knows), so this proxy needs no reference back to `Central` at all.
///
/// Holds its handler `Mutex`-guarded (matching ``CentralDelegateProxy``'s pattern):
/// assignment happens from whatever isolation domain `Central` attaches from (actor-isolated
/// code, or a `queue.sync` hop during init), and delivery arrives from CoreBluetooth's own
/// callback queue — the same queue by construction, but the `Mutex` keeps assignment and
/// delivery race-free regardless.
///
/// Forwarding stays synchronous — no `Task {` — exactly like ``CentralDelegateProxy``: by
/// the time a callback lands here, it is already running on `Central`'s own executor
/// queue, so the handler closure `Central` installed (which calls `assumeIsolated`) can
/// forward inline with no ordering hazard.
final class PeripheralDelegateProxy: NSObject, CBPeripheralDelegate {

    /// Typed `@Sendable` for the same `Mutex`-storage reason documented on
    /// `CentralDelegateProxy.handlerBox` — see that doc comment. `CBPeripheral`'s
    /// `eventHandler` setter bridges the protocol's non-`@Sendable` closure into this
    /// storage the same way.
    private let handlerBox = Mutex<(@Sendable (PeripheralEvent) -> Void)?>(nil)

    /// The `PeripheralEvent` handler this proxy forwards to.
    var handler: (@Sendable (PeripheralEvent) -> Void)? {
        get { handlerBox.withLock { $0 } }
        set { handlerBox.withLock { $0 = newValue } }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        forward(.didDiscoverServices(error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        forward(.didDiscoverCharacteristics(service: ServiceIdentifier(cbuuid: service.uuid), error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didWriteValue(characteristic: identifier, error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didUpdateValue(characteristic: identifier, value: characteristic.value, error: error as NSError?))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didUpdateNotificationState(characteristic: identifier, isNotifying: characteristic.isNotifying, error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard let identifier = characteristicIdentifier(for: characteristic) else { return }
        forward(.didDiscoverDescriptors(characteristic: identifier, error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard let identifier = descriptorIdentifier(for: descriptor) else { return }
        // Convert CoreBluetooth's untyped `Any?` descriptor value to `Data` EAGERLY, right
        // here at the proxy boundary — the raw CB payload never crosses into the actor.
        forward(.didUpdateValueForDescriptor(descriptor: identifier, value: Self.descriptorData(from: descriptor.value), error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        guard let identifier = descriptorIdentifier(for: descriptor) else { return }
        forward(.didWriteValueForDescriptor(descriptor: identifier, error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        forward(.didReadRSSI(RSSI.intValue, error: error as NSError?))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        forward(.didModifyServices(invalidatedServices.map { ServiceIdentifier(cbuuid: $0.uuid) }))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        forward(.isReadyToSendWriteWithoutResponse)
    }

    // MARK: - Forwarding

    /// Resolves `characteristic`'s owning service, or `nil` if CoreBluetooth ever hands
    /// back a characteristic with no `service` set (not expected in practice, but
    /// `CBCharacteristic.service` is optional).
    private func characteristicIdentifier(for characteristic: CBCharacteristic) -> CharacteristicIdentifier? {
        guard let service = characteristic.service else { return nil }
        return CharacteristicIdentifier(cbuuid: characteristic.uuid, service: ServiceIdentifier(cbuuid: service.uuid))
    }

    /// Resolves `descriptor`'s owning characteristic (and, transitively, its service), or
    /// `nil` if CoreBluetooth ever hands back a descriptor whose `characteristic` (or that
    /// characteristic's `service`) is unset — both are optional in CoreBluetooth, though
    /// neither is expected in practice.
    private func descriptorIdentifier(for descriptor: CBDescriptor) -> DescriptorIdentifier? {
        guard let characteristic = descriptor.characteristic,
              let identifier = characteristicIdentifier(for: characteristic) else { return nil }
        return DescriptorIdentifier(cbuuid: descriptor.uuid, characteristic: identifier)
    }

    /// Converts a `CBDescriptor.value` (typed `Any?` by CoreBluetooth) to `Data`, eagerly,
    /// at the proxy boundary. CoreBluetooth documents the concrete class per descriptor UUID:
    ///
    /// - `NSData` (Characteristic Format, Characteristic Aggregate Format) → the bytes
    ///   verbatim.
    /// - `NSString` (Characteristic User Description) → its UTF-8 bytes.
    /// - `NSNumber` (Characteristic Extended Properties, Client/Server Characteristic
    ///   Configuration, L2CAP PSM) → its 16-bit value as two little-endian bytes, the GATT
    ///   wire encoding for every one of these numeric descriptors.
    /// - `nil` (value not yet read) → `nil`.
    /// - Any other/unknown shape → `nil`, rather than guessing at a byte layout.
    private static func descriptorData(from value: Any?) -> Data? {
        switch value {
        case nil:
            return nil
        case let data as Data:
            return data
        case let string as String:
            return Data(string.utf8)
        case let number as NSNumber:
            var littleEndian = number.uint16Value.littleEndian
            return withUnsafeBytes(of: &littleEndian) { Data($0) }
        default:
            return nil
        }
    }

    private func forward(_ event: PeripheralEvent) {
        handler?(event)
    }
}

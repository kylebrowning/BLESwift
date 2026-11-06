//
//  PeripheralDelegateProxy.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import BLESwiftCompat17

/// Bridges `CBPeripheralDelegate` callbacks into a `PeripheralEvent` handler closure. It
/// implements `eventHandler` for `CBPeripheral` in the `PeripheralRemote` conformance.
///
/// There is one instance for each `CBPeripheral`. The `CBPeripheral.eventHandler` setter creates
/// it lazily and retains it through an associated object, because `CBPeripheral.delegate` is
/// `weak`.
///
/// A `Mutex` guards the handler, as in ``CentralDelegateProxy``. Forwarding is synchronous,
/// with no `Task {`, because callbacks already run on `Central`'s executor queue.
final class PeripheralDelegateProxy: NSObject, CBPeripheralDelegate {

    /// Wraps the `@Sendable` handler in a struct and not directly in the `Mutex`. See
    /// `CentralDelegateProxy.handlerBox` for the reasons.
    private struct HandlerStorage: Sendable {
        var handler: (@Sendable (PeripheralEvent) -> Void)?
    }
    private let handlerBox = Mutex(HandlerStorage())

    /// The `PeripheralEvent` handler to which this proxy forwards.
    var handler: (@Sendable (PeripheralEvent) -> Void)? {
        get { handlerBox.withLock { $0.handler } }
        set { handlerBox.withLock { $0.handler = newValue } }
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
        // Convert CoreBluetooth's untyped `Any?` descriptor value to `Data` eagerly, so the raw
        // payload never crosses into the actor.
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

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        // Wrap the raw `CBL2CAPChannel` in BLESwift's transport at this seam. The transport also
        // starts its stream pump off the actor, so nothing downstream sees a CoreBluetooth type.
        // On a failure, there is no channel to wrap.
        if let channel {
            forward(.didOpenL2CAPChannel(channel: CBL2CAPChannelTransport(channel: channel), error: nil))
        } else {
            forward(.didOpenL2CAPChannel(channel: nil, error: error as NSError?))
        }
    }

    // MARK: - Forwarding

    /// Resolves the owning service of `characteristic`. It returns `nil` if the characteristic
    /// has no `service`. This is unexpected, but `CBCharacteristic.service` is optional.
    private func characteristicIdentifier(for characteristic: CBCharacteristic) -> CharacteristicIdentifier? {
        guard let service = characteristic.service else { return nil }
        return CharacteristicIdentifier(cbuuid: characteristic.uuid, service: ServiceIdentifier(cbuuid: service.uuid))
    }

    /// Resolves the owning characteristic of `descriptor`, and through it the service. It
    /// returns `nil` if the descriptor has no `characteristic`, or that characteristic has no
    /// `service`. Both are optional in CoreBluetooth but unexpected.
    private func descriptorIdentifier(for descriptor: CBDescriptor) -> DescriptorIdentifier? {
        guard let characteristic = descriptor.characteristic,
              let identifier = characteristicIdentifier(for: characteristic) else { return nil }
        return DescriptorIdentifier(cbuuid: descriptor.uuid, characteristic: identifier)
    }

    /// Converts a `CBDescriptor.value` (`Any?`) to `Data`. CoreBluetooth documents the class
    /// for each descriptor UUID:
    ///
    /// - `NSData` (Characteristic Format, Characteristic Aggregate Format): the bytes as they
    ///   are.
    /// - `NSString` (Characteristic User Description): its UTF-8 bytes.
    /// - `NSNumber` (Characteristic Extended Properties, Client/Server Characteristic
    ///   Configuration, L2CAP PSM): its 16-bit value as two little-endian bytes, the GATT wire
    ///   encoding.
    /// - `nil` (not read yet), or any other shape: `nil`. The code does not guess a layout.
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

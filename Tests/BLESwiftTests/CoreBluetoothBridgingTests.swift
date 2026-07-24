//
//  CoreBluetoothBridgingTests.swift
//  BLESwiftTests
//

import CoreBluetooth
import Foundation
import Testing
import BLESwiftCore
@testable import BLESwift

/// Exercises the pure, radio-free value mappers at the CoreBluetooth seam:
/// ``ATTError``/`CBATTError.Code`, ``WriteType``/`CBCharacteristicWriteType`,
/// ``WarningOptions``/CoreBluetooth's connect-options dictionary,
/// ``AttributePermissions``/`CBAttributePermissions`, ``BluetoothAuthorization``/
/// `CBManagerAuthorization`, ``PeripheralConnectionState``/`CBPeripheralState`,
/// the identifier types' `CBUUID` bridge, and the ``CharacteristicProperties``→
/// `CBCharacteristicProperties` `.cbProperties` getter (the reverse of the direction already
/// covered by `CharacteristicPropertiesTests`).
@Suite("CoreBluetooth bridging")
struct CoreBluetoothBridgingTests {

    // MARK: - ATTError+CB

    @Test("a known ATTError maps to the matching CBATTError.Code")
    func attErrorMapsToMatchingCBCode() {
        #expect(ATTError.invalidHandle.cbATTErrorCode == CBATTError.Code.invalidHandle)
        #expect(ATTError.writeNotPermitted.cbATTErrorCode == CBATTError.Code.writeNotPermitted)
        #expect(ATTError.insufficientResources.cbATTErrorCode == CBATTError.Code.insufficientResources)
    }

    @Test("CBATTError.Code.success maps to nil, not an ATTError")
    func cbSuccessMapsToNil() {
        #expect(CBATTError.Code.success.bleSwiftATTError == nil)
    }

    @Test("a representative ATTError round-trips through CBATTError.Code")
    func attErrorRoundTrips() {
        let original = ATTError.insufficientAuthentication
        let cbCode = original.cbATTErrorCode
        #expect(cbCode.bleSwiftATTError == original)
    }

    @Test("every ATTError case round-trips through CBATTError.Code")
    func everyATTErrorRoundTrips() {
        let allCases: [ATTError] = [
            .invalidHandle, .readNotPermitted, .writeNotPermitted, .invalidPdu,
            .insufficientAuthentication, .requestNotSupported, .invalidOffset,
            .insufficientAuthorization, .prepareQueueFull, .attributeNotFound,
            .attributeNotLong, .insufficientEncryptionKeySize, .invalidAttributeValueLength,
            .unlikelyError, .insufficientEncryption, .unsupportedGroupType,
            .insufficientResources
        ]
        for error in allCases {
            #expect(error.cbATTErrorCode.bleSwiftATTError == error)
        }
    }

    // MARK: - WriteType+CB

    @Test("WriteType.withResponse maps to CBCharacteristicWriteType.withResponse")
    func writeTypeWithResponse() {
        #expect(WriteType.withResponse.cbWriteType == CBCharacteristicWriteType.withResponse)
    }

    @Test("WriteType.withoutResponse maps to CBCharacteristicWriteType.withoutResponse")
    func writeTypeWithoutResponse() {
        #expect(WriteType.withoutResponse.cbWriteType == CBCharacteristicWriteType.withoutResponse)
    }

    // MARK: - WarningOptions+CB

    @Test("WarningOptions.cbConnectOptions maps each toggle to its CoreBluetooth key")
    func warningOptionsProducesExpectedDictionary() {
        let options = WarningOptions(
            notifyOnConnection: true,
            notifyOnDisconnection: false,
            notifyOnNotification: true
        )
        let dict = options.cbConnectOptions
        #expect(dict[CBConnectPeripheralOptionNotifyOnConnectionKey] == true)
        #expect(dict[CBConnectPeripheralOptionNotifyOnDisconnectionKey] == false)
        #expect(dict[CBConnectPeripheralOptionNotifyOnNotificationKey] == true)
    }

    @Test("WarningOptions.default maps to all-false")
    func warningOptionsDefaultMapsToAllFalse() {
        let dict = WarningOptions.default.cbConnectOptions
        #expect(dict[CBConnectPeripheralOptionNotifyOnConnectionKey] == false)
        #expect(dict[CBConnectPeripheralOptionNotifyOnDisconnectionKey] == false)
        #expect(dict[CBConnectPeripheralOptionNotifyOnNotificationKey] == false)
    }

    // MARK: - AttributePermissions+CB

    @Test("AttributePermissions round-trips through CBAttributePermissions for representative sets")
    func attributePermissionsRoundTrips() {
        let cases: [AttributePermissions] = [
            [],
            .readable,
            .writeable,
            .readEncryptionRequired,
            .writeEncryptionRequired,
            [.readable, .writeable],
            [.readable, .writeable, .readEncryptionRequired, .writeEncryptionRequired]
        ]
        for permissions in cases {
            let cbPermissions = permissions.cbPermissions
            #expect(AttributePermissions(cbPermissions) == permissions)
        }
    }

    @Test("AttributePermissions.cbPermissions is a raw-value passthrough")
    func attributePermissionsRawValuePassthrough() {
        let permissions: AttributePermissions = [.readable, .writeEncryptionRequired]
        #expect(permissions.cbPermissions.rawValue == permissions.rawValue)
    }

    // MARK: - BluetoothAuthorization+CB

    @Test("every CBManagerAuthorization case maps to the same-named BluetoothAuthorization")
    func bluetoothAuthorizationMapsAllCases() {
        #expect(BluetoothAuthorization(CBManagerAuthorization.notDetermined) == .notDetermined)
        #expect(BluetoothAuthorization(CBManagerAuthorization.restricted) == .restricted)
        #expect(BluetoothAuthorization(CBManagerAuthorization.denied) == .denied)
        #expect(BluetoothAuthorization(CBManagerAuthorization.allowedAlways) == .allowedAlways)
    }

    // MARK: - PeripheralConnectionState+CB

    @Test("every CBPeripheralState case maps to the same-named PeripheralConnectionState")
    func peripheralConnectionStateMapsAllCases() {
        #expect(PeripheralConnectionState(CBPeripheralState.connecting) == .connecting)
        #expect(PeripheralConnectionState(CBPeripheralState.connected) == .connected)
        #expect(PeripheralConnectionState(CBPeripheralState.disconnecting) == .disconnecting)
        #expect(PeripheralConnectionState(CBPeripheralState.disconnected) == .disconnected)
    }

    // MARK: - Identifiers+CBUUID

    @Test("ServiceIdentifier round-trips through CBUUID, preserving a 16-bit UUID")
    func serviceIdentifierRoundTripsShortUUID() {
        let original = ServiceIdentifier(uuid: "180D")
        let roundTripped = ServiceIdentifier(cbuuid: original.cbuuid)
        #expect(roundTripped == original)
        #expect(roundTripped.cbuuid == original.cbuuid)
    }

    @Test("ServiceIdentifier round-trips through CBUUID, preserving a full 128-bit UUID")
    func serviceIdentifierRoundTripsLongUUID() {
        let original = ServiceIdentifier(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        let roundTripped = ServiceIdentifier(cbuuid: original.cbuuid)
        #expect(roundTripped == original)
        #expect(roundTripped.cbuuid == original.cbuuid)
    }

    @Test("CharacteristicIdentifier round-trips through CBUUID, preserving both UUID and service")
    func characteristicIdentifierRoundTrips() {
        let service = ServiceIdentifier(uuid: "180D")
        let original = CharacteristicIdentifier(uuid: "2A37", service: service)
        let roundTripped = CharacteristicIdentifier(cbuuid: original.cbuuid, service: service)
        #expect(roundTripped == original)
        #expect(roundTripped.cbuuid == original.cbuuid)
    }

    @Test("CharacteristicIdentifier round-trips a full 128-bit UUID through CBUUID")
    func characteristicIdentifierRoundTripsLongUUID() {
        let service = ServiceIdentifier(uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        let original = CharacteristicIdentifier(
            uuid: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
            service: service
        )
        let roundTripped = CharacteristicIdentifier(cbuuid: original.cbuuid, service: service)
        #expect(roundTripped == original)
        #expect(roundTripped.cbuuid == original.cbuuid)
    }

    @Test("DescriptorIdentifier round-trips through CBUUID, preserving the owning characteristic")
    func descriptorIdentifierRoundTrips() {
        let service = ServiceIdentifier(uuid: "180D")
        let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)
        let original = DescriptorIdentifier(uuid: "2902", characteristic: characteristic)
        let roundTripped = DescriptorIdentifier(cbuuid: original.cbuuid, characteristic: characteristic)
        #expect(roundTripped == original)
        #expect(roundTripped.cbuuid == original.cbuuid)
    }

    // MARK: - CharacteristicProperties+CB (.cbProperties getter, the BLESwift→CB direction)

    @Test("each CharacteristicProperties bit maps to its CBCharacteristicProperties member")
    func cbPropertiesMapsEachBit() {
        #expect(CharacteristicProperties.read.cbProperties == CBCharacteristicProperties.read)
        #expect(CharacteristicProperties.write.cbProperties == CBCharacteristicProperties.write)
        #expect(
            CharacteristicProperties.writeWithoutResponse.cbProperties
                == CBCharacteristicProperties.writeWithoutResponse
        )
        #expect(CharacteristicProperties.notify.cbProperties == CBCharacteristicProperties.notify)
        #expect(CharacteristicProperties.indicate.cbProperties == CBCharacteristicProperties.indicate)
        #expect(
            CharacteristicProperties.authenticatedSignedWrites.cbProperties
                == CBCharacteristicProperties.authenticatedSignedWrites
        )
        #expect(
            CharacteristicProperties.extendedProperties.cbProperties
                == CBCharacteristicProperties.extendedProperties
        )
        #expect(CharacteristicProperties.broadcast.cbProperties == CBCharacteristicProperties.broadcast)
    }

    @Test("an empty CharacteristicProperties maps to an empty CBCharacteristicProperties")
    func cbPropertiesMapsEmpty() {
        let empty: CharacteristicProperties = []
        #expect(empty.cbProperties == [])
    }

    @Test("a combined CharacteristicProperties round-trips through CBCharacteristicProperties")
    func cbPropertiesRoundTripsCombined() {
        let combined: CharacteristicProperties = [.read, .write, .notify, .indicate]
        let cbCombined = combined.cbProperties
        #expect(cbCombined == [.read, .write, .notify, .indicate])
        #expect(CharacteristicProperties(cbCombined) == combined)
    }

    @Test("every CharacteristicProperties bit round-trips through CBCharacteristicProperties")
    func cbPropertiesRoundTripsEveryBit() {
        let all: CharacteristicProperties = [
            .read, .write, .writeWithoutResponse, .notify, .indicate,
            .authenticatedSignedWrites, .extendedProperties, .broadcast
        ]
        #expect(CharacteristicProperties(all.cbProperties) == all)
    }
}

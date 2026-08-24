//
//  DeviceInformation.swift
//  BLESwiftProfiles
//

import BLESwift
import BLESwiftCore
import Foundation

/// The strings exposed by the Bluetooth SIG "Device Information" service (`0x180A`).
///
/// This is an *aggregate* of up to seven independent UTF-8 String characteristics, each of
/// which is optional on a given peripheral — so `DeviceInformation` is not itself
/// ``Receivable``. Read it with ``BLESwift/Peripheral/readDeviceInformation(timeout:)``,
/// which reads whichever characteristics the peripheral exposes and leaves the rest `nil`.
///
/// Characteristics (all UTF-8 strings, GSS §3):
/// - Manufacturer Name String (`0x2A29`)
/// - Model Number String (`0x2A24`)
/// - Serial Number String (`0x2A25`)
/// - Firmware Revision String (`0x2A26`)
/// - Hardware Revision String (`0x2A27`)
/// - Software Revision String (`0x2A28`)
public struct DeviceInformation: Sendable, Equatable {

    /// The Bluetooth SIG-assigned Device Information service (`0x180A`).
    public static let service = ServiceIdentifier(uuid: "180A")

    /// Manufacturer Name String characteristic (`0x2A29`).
    public static let manufacturerNameCharacteristic = CharacteristicIdentifier(uuid: "2A29", service: service)
    /// Model Number String characteristic (`0x2A24`).
    public static let modelNumberCharacteristic = CharacteristicIdentifier(uuid: "2A24", service: service)
    /// Serial Number String characteristic (`0x2A25`).
    public static let serialNumberCharacteristic = CharacteristicIdentifier(uuid: "2A25", service: service)
    /// Firmware Revision String characteristic (`0x2A26`).
    public static let firmwareRevisionCharacteristic = CharacteristicIdentifier(uuid: "2A26", service: service)
    /// Hardware Revision String characteristic (`0x2A27`).
    public static let hardwareRevisionCharacteristic = CharacteristicIdentifier(uuid: "2A27", service: service)
    /// Software Revision String characteristic (`0x2A28`).
    public static let softwareRevisionCharacteristic = CharacteristicIdentifier(uuid: "2A28", service: service)

    /// Every Device Information String characteristic, in declaration order.
    public static let characteristics: [CharacteristicIdentifier] = [
        manufacturerNameCharacteristic,
        modelNumberCharacteristic,
        serialNumberCharacteristic,
        firmwareRevisionCharacteristic,
        hardwareRevisionCharacteristic,
        softwareRevisionCharacteristic,
    ]

    public let manufacturerName: String?
    public let modelNumber: String?
    public let serialNumber: String?
    public let firmwareRevision: String?
    public let hardwareRevision: String?
    public let softwareRevision: String?

    public init(
        manufacturerName: String? = nil,
        modelNumber: String? = nil,
        serialNumber: String? = nil,
        firmwareRevision: String? = nil,
        hardwareRevision: String? = nil,
        softwareRevision: String? = nil
    ) {
        self.manufacturerName = manufacturerName
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.softwareRevision = softwareRevision
    }
}

//
//  L2CAPPSM.swift
//  BLESwiftCore
//

/// A Protocol/Service Multiplexer (PSM) that names one L2CAP channel endpoint on a peripheral. It
/// is the BLESwift-owned counterpart of `CBL2CAPPSM` in CoreBluetooth.
///
/// A peripheral typically publishes the dynamic PSM to connect on in a GATT characteristic. Read
/// the characteristic, wrap the value in an `L2CAPPSM`, and pass it to
/// `Peripheral.openL2CAPChannel(psm:timeout:)`.
public struct L2CAPPSM: Sendable, CustomStringConvertible {

    /// The raw 16-bit PSM value. It matches CoreBluetooth's `CBL2CAPPSM`.
    public let rawValue: UInt16

    /// Creates an `L2CAPPSM` from its raw 16-bit value.
    public init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// A human-readable description of this PSM.
    public var description: String {
        "PSM(\(rawValue))"
    }
}

extension L2CAPPSM: Hashable {}

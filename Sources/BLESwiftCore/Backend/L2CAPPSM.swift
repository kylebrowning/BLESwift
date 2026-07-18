//
//  L2CAPPSM.swift
//  BLESwiftCore
//

/// A Protocol/Service Multiplexer (PSM) naming one L2CAP channel endpoint on a peripheral.
///
/// BLESwift-owned counterpart to CoreBluetooth's `CBL2CAPPSM` (itself a bare `UInt16`),
/// kept in `BLESwiftCore` so that a CoreBluetooth type never leaks into the public API —
/// the `CBL2CAPPSM` bridge lives in the `BLESwift` module, built on this type's public
/// members (the same seam discipline ``ServiceIdentifier``/``CharacteristicIdentifier``
/// follow for `CBUUID`).
///
/// A peripheral typically publishes the dynamic PSM to connect on via a GATT
/// characteristic; read it, wrap it in an `L2CAPPSM`, and pass it to
/// `Peripheral.openL2CAPChannel(psm:timeout:)`.
public struct L2CAPPSM: Sendable, CustomStringConvertible {

    /// The raw 16-bit PSM value, matching CoreBluetooth's `CBL2CAPPSM`.
    public let rawValue: UInt16

    /// Creates an `L2CAPPSM` from its raw 16-bit value.
    ///
    /// - Parameter rawValue: The PSM value — for a dynamically-published channel, the value
    ///   the peripheral advertised.
    public init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// A human-readable description of this PSM.
    public var description: String {
        "PSM(\(rawValue))"
    }
}

extension L2CAPPSM: Hashable {}

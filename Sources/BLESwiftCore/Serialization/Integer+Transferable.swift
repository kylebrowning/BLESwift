//
//  Integer+Transferable.swift
//  BLESwiftCore
//

import Foundation

extension FixedWidthInteger where Self: BitwiseCopyable {

    /// Encodes this integer as its raw, machine-endian byte representation.
    public func toBluetoothData() throws -> Data {
        var value = self
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    /// Decodes an integer from its raw, machine-endian byte representation.
    ///
    /// - Throws: ``BLESwiftError/dataOutOfBounds(start:length:count:)`` if `bluetoothData`
    ///   is not exactly `MemoryLayout<Self>.size` bytes.
    public init(bluetoothData: Data) throws {
        self = try bluetoothData.extract(start: 0, length: MemoryLayout<Self>.size)
    }
}

// Fixed-width integer types only — deliberately not `Int`/`UInt`, whose size is
// platform-dependent and therefore unsafe to serialize across devices.

/// `Int8` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension Int8: Transmittable, Receivable {}
/// `Int16` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension Int16: Transmittable, Receivable {}
/// `Int32` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension Int32: Transmittable, Receivable {}
/// `Int64` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension Int64: Transmittable, Receivable {}

/// `UInt8` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension UInt8: Transmittable, Receivable {}
/// `UInt16` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension UInt16: Transmittable, Receivable {}
/// `UInt32` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension UInt32: Transmittable, Receivable {}
/// `UInt64` conforms to ``Transmittable`` and ``Receivable`` via its raw byte representation.
extension UInt64: Transmittable, Receivable {}

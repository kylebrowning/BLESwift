//
//  WriteType.swift
//  BLESwiftCore
//

/// Whether a GATT write should wait for the peripheral's confirmation.
///
/// BLESwift-owned; the backend's native write-type mapping lives in the `BLESwift`
/// module — this type never exposes a CoreBluetooth type in its own public API.
public enum WriteType: Sendable, Hashable {

    /// Wait for the peripheral to confirm the write.
    case withResponse

    /// Don't wait for confirmation — the backend delivers no completion callback for
    /// this write type.
    case withoutResponse
}

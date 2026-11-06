//
//  WriteType.swift
//  BLESwiftCore
//

/// Whether a GATT write must wait for the peripheral's confirmation.
///
/// BLESwift owns this type, so no CoreBluetooth type appears in its public API. The `BLESwift`
/// module maps it to the backend's native write type.
public enum WriteType: Sendable, Hashable {

    /// Wait for the peripheral to confirm the write.
    case withResponse

    /// Do not wait for confirmation. The backend delivers no completion callback for this write
    /// type.
    case withoutResponse
}

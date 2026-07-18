//
//  ATTError.swift
//  BLESwiftCore
//

/// An Attribute Protocol (ATT) failure code your peripheral returns when it cannot fulfil a
/// read or write request — the failure half of a `PeripheralHost/respond(to:with:)-(ReadRequest,_)`
/// / `PeripheralHost/respond(to:with:)-(WriteRequest,_)` result.
///
/// A `Sendable`, value-type mirror of CoreBluetooth's `CBATTError.Code` (excluding its
/// `success` case, which the success half of a `Result` already expresses). The raw values
/// match `CBATTError.Code`'s exactly, so the `BLESwift` module bridges the two by raw value
/// at the CoreBluetooth seam. Conforms to `Error` so it slots directly into
/// `Result<_, ATTError>`.
public enum ATTError: Int, Error, Sendable, Hashable {

    /// The attribute handle is invalid on this peripheral.
    case invalidHandle = 1
    /// The attribute's value cannot be read.
    case readNotPermitted = 2
    /// The attribute's value cannot be written.
    case writeNotPermitted = 3
    /// The attribute Protocol Data Unit was invalid.
    case invalidPdu = 4
    /// Reading or writing the attribute requires authentication.
    case insufficientAuthentication = 5
    /// The attribute server does not support the request.
    case requestNotSupported = 6
    /// The specified offset is past the end of the attribute's value.
    case invalidOffset = 7
    /// Reading or writing the attribute requires authorization.
    case insufficientAuthorization = 8
    /// The prepare-write queue is full.
    case prepareQueueFull = 9
    /// No attribute was found within the given handle range.
    case attributeNotFound = 10
    /// The attribute cannot be read or written using a Read Blob or Prepare Write request.
    case attributeNotLong = 11
    /// The encryption key size is insufficient.
    case insufficientEncryptionKeySize = 12
    /// The attribute value's length is invalid for the operation.
    case invalidAttributeValueLength = 13
    /// The request encountered an unlikely error and could not be completed.
    case unlikelyError = 14
    /// Reading or writing the attribute requires an encrypted link.
    case insufficientEncryption = 15
    /// The attribute type is not a supported grouping attribute.
    case unsupportedGroupType = 16
    /// Insufficient resources to complete the request.
    case insufficientResources = 17
}

//
//  ATTError+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

/// `CBATTError.Code` bridging for ``ATTError``. The two share raw-value layout by
/// construction (``ATTError`` omits `.success`, which the success half of a `Result`
/// expresses instead), so the bridge is a raw-value passthrough.
extension ATTError {

    /// The `CBATTError.Code` representation of this failure. An unrecognized raw value maps
    /// to `.unlikelyError` (unreachable for the fixed cases here; belt-and-suspenders).
    var cbATTErrorCode: CBATTError.Code {
        CBATTError.Code(rawValue: rawValue) ?? .unlikelyError
    }
}

extension CBATTError.Code {

    /// Maps a `CBATTError.Code` to its ``ATTError``, or `nil` for `.success` (which is not
    /// an error).
    var bleSwiftATTError: ATTError? {
        self == .success ? nil : ATTError(rawValue: rawValue)
    }
}

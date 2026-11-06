//
//  ATTError+CB.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

/// `CBATTError.Code` bridging for ``ATTError``. The two have the same raw-value layout, so the
/// bridge passes the raw value through. ``ATTError`` omits `.success`.
extension ATTError {

    /// The `CBATTError.Code` for this failure. An unrecognized raw value maps to
    /// `.unlikelyError`.
    var cbATTErrorCode: CBATTError.Code {
        CBATTError.Code(rawValue: rawValue) ?? .unlikelyError
    }
}

extension CBATTError.Code {

    /// Maps a `CBATTError.Code` to its ``ATTError``. Returns `nil` for `.success`, because it
    /// is not an error.
    var bleSwiftATTError: ATTError? {
        self == .success ? nil : ATTError(rawValue: rawValue)
    }
}

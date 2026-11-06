//
//  Exports.swift
//  BLESwift
//

/// Re-exports `BLESwiftCore` from `BLESwift`. Thus each type that Core owns stays visible
/// through a plain `import BLESwift`. Examples are `PeripheralIdentifier`, `BLESwiftError`,
/// `Receivable`, `Transmittable`, and `AdvertisementData`.
@_exported import BLESwiftCore

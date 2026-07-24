//
//  Exports.swift
//  BLESwift
//

/// Re-exports `BLESwiftCore` from `BLESwift`, so every Core-owned type
/// (`PeripheralIdentifier`, `BLESwiftError`, `Receivable`/`Transmittable`,
/// `AdvertisementData`, …) stays visible through a plain `import BLESwift`.
@_exported import BLESwiftCore

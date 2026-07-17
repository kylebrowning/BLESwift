//
//  Exports.swift
//  BLESwift
//

/// Re-exports `BLESwiftCore` from `BLESwift`.
///
/// BLESwift shipped as a single, unsplit module before the Core extraction (plans/03);
/// existing `import BLESwift` code must keep compiling unchanged afterward, so every
/// Core-owned type (`PeripheralIdentifier`, `BLESwiftError`, `Receivable`/`Transmittable`,
/// `AdvertisementData`, …) needs to remain visible through a plain `import BLESwift`.
///
/// This is a deliberate divergence from the APNSwift precedent this split otherwise
/// follows: APNSwift was *born* split (`APNSCore` + `APNS`, no re-export — consumers
/// `import` both side by side), so it never had a pre-split API to stay compatible with.
/// BLESwift did, hence the re-export.
@_exported import BLESwiftCore

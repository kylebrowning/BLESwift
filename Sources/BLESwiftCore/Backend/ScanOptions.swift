//
//  ScanOptions.swift
//  BLESwiftCore
//

/// Options for a single backend scan request.
///
/// BLESwift-owned; never exposes CoreBluetooth's `[String: Any]` scan-options dictionary
/// in its public API or in the backend seam. The CoreBluetooth conformance builds that
/// dictionary internally, in the `BLESwift` module.
public struct ScanOptions: Sendable, Hashable {

    /// Whether to keep reporting an already-discovered peripheral's further sightings.
    /// Mirrors `CBCentralManagerScanOptionAllowDuplicatesKey`.
    public var allowDuplicates: Bool

    /// Creates a `ScanOptions`.
    public init(allowDuplicates: Bool = false) {
        self.allowDuplicates = allowDuplicates
    }
}

//
//  ScanOptions.swift
//  BLESwiftCore
//

/// Options for a single backend scan request.
///
/// BLESwift owns this type, so CoreBluetooth's `[String: Any]` scan-options dictionary never
/// appears in the public API or the backend seam. The CoreBluetooth conformance in the `BLESwift`
/// module builds that dictionary internally.
public struct ScanOptions: Sendable, Hashable {

    /// Whether to keep reporting sightings of a peripheral that is already discovered.
    /// Mirrors `CBCentralManagerScanOptionAllowDuplicatesKey`.
    public var allowDuplicates: Bool

    /// Creates a `ScanOptions`.
    public init(allowDuplicates: Bool = false) {
        self.allowDuplicates = allowDuplicates
    }
}

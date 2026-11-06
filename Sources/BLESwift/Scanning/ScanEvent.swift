//
//  ScanEvent.swift
//  BLESwift
//

import BLESwiftCore

/// An event from
/// ``Central/scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``.
/// To stop the scan, break out of the stream or cancel the task that consumes it. A connection
/// does not stop a live scan.
public enum ScanEvent: Sendable {

    /// The scan sighted a peripheral for the first time in this scan. This event also occurs
    /// when the scan sights a peripheral again after it reported it as ``lost(_:)``.
    case discovered(Discovery)

    /// The scan sighted a peripheral again after it reported ``discovered(_:)``. The scan
    /// emits this event only with `allowDuplicates: true`.
    case updated(Discovery)

    /// The scan did not sight a known peripheral again within `lossTimeout`. The scan emits
    /// this event only with `allowDuplicates: true`. A later sighting is a new
    /// ``discovered(_:)``, not ``updated(_:)``.
    case lost(Discovery)
}

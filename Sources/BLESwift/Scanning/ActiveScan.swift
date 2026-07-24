//
//  ActiveScan.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// The state of a single in-progress `Central.scan(...)` call.
///
/// Actor-confined: every stored property here is read and written only from within
/// `Central`'s isolation — `Central` holds at most one `ActiveScan` at a time (see
/// ``BLESwiftError/alreadyScanning``). A reference type (not `Sendable`) so its
/// per-peripheral loss-timer and timeout `Task` bookkeeping can be mutated in place. Never
/// passed across an isolation boundary or captured by an escaping closure.
final class ActiveScan {

    /// The continuation for the `AsyncThrowingStream<ScanEvent, Error>` this scan vends to
    /// its caller. `Central` yields ``ScanEvent``s to it and finishes it (with or without an
    /// error) to end the scan.
    let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation

    /// Whether this scan was started with `allowDuplicates: true` — gates
    /// ``ScanEvent/updated(_:)`` emission and per-peripheral loss tracking.
    let allowDuplicates: Bool

    /// The minimum absolute RSSI delta (in dBm) required for a repeat sighting to be
    /// reported as ``ScanEvent/updated(_:)``. `nil` disables throttling.
    let rssiThreshold: Int?

    /// How long a sighted peripheral may go unseen before it is reported as
    /// ``ScanEvent/lost(_:)``. Only meaningful when ``allowDuplicates`` is `true`.
    let lossTimeout: Duration

    /// Every peripheral sighted so far in this scan session, keyed by identifier.
    var discoveries: [UUID: Discovery] = [:]

    /// One loss-expiry `Task` per currently-sighted peripheral, keyed by identifier.
    /// Cancelled and replaced on every re-sighting; cancelled outright when the scan ends.
    /// Only populated when ``allowDuplicates`` is `true`.
    var lossTimers: [UUID: Task<Void, Never>] = [:]

    /// The overall scan-duration timeout `Task`, if this scan was started with a non-`nil`
    /// `timeout:`. Cancelled when the scan ends for any other reason.
    var timeoutTask: Task<Void, Never>?

    #if os(iOS)
    /// The `NotificationCenter` observer token for
    /// `UIApplication.didEnterBackgroundNotification`, installed when this scan's
    /// parameters require a backgrounding guard (see
    /// `Central.installBackgroundGuardIfNeeded(scan:allowDuplicates:missingServices:)`).
    /// Removed when the scan ends.
    var backgroundObserver: NSObjectProtocol?
    #endif

    /// Creates the state for a new scan session.
    init(
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        allowDuplicates: Bool,
        rssiThreshold: Int?,
        lossTimeout: Duration
    ) {
        self.continuation = continuation
        self.allowDuplicates = allowDuplicates
        self.rssiThreshold = rssiThreshold
        self.lossTimeout = lossTimeout
    }
}

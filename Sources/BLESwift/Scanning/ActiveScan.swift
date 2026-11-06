//
//  ActiveScan.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// The state of a single in-progress `Central.scan(...)` call.
///
/// This type is actor-confined. Read and write its properties only from `Central`'s isolation.
/// `Central` holds at most one `ActiveScan` (see ``BLESwiftError/alreadyScanning``). It is a
/// non-`Sendable` reference type, so `Central` can change the loss-timer and timeout
/// bookkeeping in place. Never pass it across an isolation boundary or capture it in an
/// escaping closure.
final class ActiveScan {

    /// The continuation of the `AsyncThrowingStream<ScanEvent, Error>` that this scan returns.
    /// `Central` yields ``ScanEvent`` values to it and finishes it to end the scan.
    let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation

    /// Whether this scan started with `allowDuplicates: true`. It controls
    /// ``ScanEvent/updated(_:)`` events and loss tracking.
    let allowDuplicates: Bool

    /// The minimum absolute RSSI change, in dBm, for a repeat sighting to produce
    /// ``ScanEvent/updated(_:)``. `nil` disables throttling.
    let rssiThreshold: Int?

    /// How long a sighted peripheral can stay unseen before the scan reports
    /// ``ScanEvent/lost(_:)``. It applies only when ``allowDuplicates`` is `true`.
    let lossTimeout: Duration

    /// The actor-side match criteria. `Central` applies them to every sighting before it
    /// records the sighting or emits an event. `nil` matches everything.
    let filter: ScanFilter?

    /// Every peripheral that this scan sighted so far, by identifier.
    var discoveries: [UUID: Discovery] = [:]

    /// The loss-expiry `Task` of each sighted peripheral, by identifier. Each new sighting
    /// replaces the task. The end of the scan cancels all of them. It is filled only when
    /// ``allowDuplicates`` is `true`.
    var lossTimers: [UUID: Task<Void, Never>] = [:]

    /// The `Task` for the overall scan timeout. It exists if the scan started with a
    /// non-`nil` `timeout:`. Another end of the scan cancels it.
    var timeoutTask: Task<Void, Never>?

    #if os(iOS)
    /// The observer token for `UIApplication.didEnterBackgroundNotification`. `Central`
    /// installs it when the scan parameters need a background guard (see
    /// `Central.installBackgroundGuardIfNeeded(scan:allowDuplicates:missingServices:)`) and
    /// removes it when the scan ends.
    var backgroundObserver: NSObjectProtocol?
    #endif

    /// Creates the state for a new scan session.
    init(
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation,
        allowDuplicates: Bool,
        rssiThreshold: Int?,
        lossTimeout: Duration,
        filter: ScanFilter? = nil
    ) {
        self.continuation = continuation
        self.allowDuplicates = allowDuplicates
        self.rssiThreshold = rssiThreshold
        self.lossTimeout = lossTimeout
        self.filter = filter
    }
}

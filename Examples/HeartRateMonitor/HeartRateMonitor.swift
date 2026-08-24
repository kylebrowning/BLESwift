//
//  HeartRateMonitor.swift
//  BLESwift Examples
//
//  A minimal, real-API worked example: scan for a Bluetooth heart-rate monitor, connect
//  to it, and stream its heart-rate notifications.
//
//  This file is example source, not a library or test target: it is not referenced by
//  `Package.swift` and is not built by `swift build`/`swift test`. It exists to be read
//  (and independently type-checked against a built `BLESwift` module) as a worked sample —
//  see the "Getting Started" and "Reading, Writing & Notifications" DocC articles for the
//  narrated walkthrough this code backs.
//

import BLESwift
import BLESwiftProfiles
import Foundation

// `HeartRateMeasurement` and its Heart Rate service/characteristic identifiers now ship in
// the `BLESwiftProfiles` product — see `HeartRateMeasurement.characteristic` /
// `HeartRateMeasurement.service` below.

/// Drives the scan → connect → subscribe flow against the first heart-rate monitor found.
enum HeartRateMonitor {

    /// Scans for, connects to, and streams heart-rate readings from the first peripheral
    /// seen advertising the Heart Rate service — printing each reading as it arrives.
    ///
    /// Runs until its enclosing `Task` is cancelled or the connection ends.
    static func run() async throws {
        let central = Central(configuration: Configuration(showPowerAlert: true))

        // Wait for the radio to be ready before scanning.
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        // Scan until a peripheral advertising the Heart Rate service turns up, then stop
        // (breaking out of the loop ends the scan — see the "Scanning" article).
        var found: PeripheralIdentifier?
        for try await event in await central.scan(services: [HeartRateMeasurement.service]) {
            if case .discovered(let discovery) = event {
                found = discovery.peripheral
                break
            }
        }

        guard let identifier = found else {
            print("No heart-rate monitor found.")
            return
        }

        print("Connecting to \(identifier)...")
        let peripheral = try await central.connect(identifier, reconnect: .always(maxAttempts: 5))

        // React to connection lifecycle in the background — including resubscribing to
        // notifications after a successful reconnect, since notification streams end at
        // disconnect and do not re-arm themselves (see "Connections & Reconnection").
        let connectionWatcher = Task {
            for await event in await central.connectionEvents() {
                switch event {
                case .connecting(let id):
                    print("Connecting to \(id)...")
                case .connected(let id):
                    print("Connected to \(id).")
                case .disconnected(let id, let error, let willReconnect):
                    print("Disconnected from \(id): \(String(describing: error)); willReconnect: \(willReconnect)")
                case .reconnecting(let id, let attempt):
                    print("Reconnect attempt \(attempt) for \(id)...")
                case .notificationsRestored(let id, let restored, let failed):
                    print("Notifications restored for \(id): \(restored.count) ok, \(failed.count) failed")
                }
            }
        }
        defer { connectionWatcher.cancel() }

        let readings: AsyncThrowingStream<HeartRateMeasurement, Error> = peripheral.notifications(
            for: HeartRateMeasurement.characteristic,
            policy: .bufferingNewest(1)
        )

        for try await reading in readings {
            print("Heart rate: \(reading.beatsPerMinute) bpm")
        }
    }
}

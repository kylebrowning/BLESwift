//
//  HeartRateMonitor.swift
//  BLESwift Examples
//
//  A minimal worked example with the real API. It scans for a Bluetooth heart-rate monitor, connects
//  to it, and streams its heart-rate notifications.
//
//  This file is example source, not a library or a test target. `Package.swift` does not reference
//  it, and `swift build` and `swift test` do not build it. Read it as a worked sample, or type-check
//  it independently against a built `BLESwift` module. The "Getting Started" and "Reading, Writing &
//  Notifications" DocC articles give the narrated walkthrough.
//

import BLESwift
import BLESwiftProfiles
import Foundation

// `HeartRateMeasurement` and its Heart Rate service and characteristic identifiers are part of the
// `BLESwiftProfiles` product. See `HeartRateMeasurement.characteristic` and
// `HeartRateMeasurement.service` below.

/// Drives the scan → connect → subscribe flow against the first heart-rate monitor found.
enum HeartRateMonitor {

    /// Scans for the first peripheral that advertises the Heart Rate service, connects to it, and
    /// prints each heart-rate reading as it arrives. Runs until its enclosing `Task` is cancelled
    /// or the connection ends.
    static func run() async throws {
        let central = Central(configuration: Configuration(showPowerAlert: true))

        // Wait until the radio is ready, then scan.
        for await state in await central.stateEvents() {
            if state == .poweredOn { break }
        }

        // Scan until a peripheral that advertises the Heart Rate service appears, then stop. A
        // `break` out of the loop ends the scan (see the "Scanning" article).
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

        // Handle the connection lifecycle in the background. After a successful reconnect,
        // subscribe to the notifications again, because notification streams end at disconnect and
        // do not restart (see "Connections & Reconnection").
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

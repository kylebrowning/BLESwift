//
//  BLESwiftErrorTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore

/// Exercises ``BLESwiftError/errorDescription``, constructing a representative value of
/// every case and asserting the description is non-`nil` and contains the expected
/// substring. Pure `BLESwiftCore`, no CoreBluetooth or `@testable` needed.
@Suite("BLESwiftError descriptions")
struct BLESwiftErrorTests {

    private static let peripheral = PeripheralIdentifier(uuid: UUID(), name: "Widget")
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let descriptor = DescriptorIdentifier(uuid: "2902", characteristic: characteristic)

    private func description(_ error: BLESwiftError) -> String {
        guard let description = error.errorDescription else {
            Issue.record("Expected a non-nil errorDescription for \(error)")
            return ""
        }
        return description
    }

    @Test("every BLESwiftError case has a non-nil, expected errorDescription")
    func everyCaseHasExpectedDescription() {
        #expect(description(.bluetoothUnavailable).contains("Bluetooth unavailable"))

        #expect(description(.duplicateConnect(Self.peripheral)).contains(Self.peripheral.description))

        #expect(description(.multipleDisconnectNotSupported).contains("Multiple disconnect"))

        #expect(description(.connectionTimedOut).contains("Connection timed out"))

        #expect(description(.notConnected).contains("Not connected"))

        #expect(description(.missingService(Self.service)).contains(Self.service.uuidString))

        #expect(description(.missingCharacteristic(Self.characteristic)).contains(Self.characteristic.uuidString))

        #expect(description(.missingDescriptor(Self.descriptor)).contains(Self.descriptor.uuidString))

        #expect(description(.cancelled).contains("Cancelled"))

        #expect(description(.explicitDisconnect).contains("Explicit disconnect"))

        #expect(description(.unexpectedDisconnect).contains("Unexpected disconnect"))

        #expect(description(.listenTimedOut).contains("Listen timed out"))

        #expect(description(.readFailed).contains("Read failed"))

        #expect(description(.writeFailed).contains("Write failed"))

        #expect(description(.missingData).contains("No data"))

        #expect(
            description(.dataOutOfBounds(start: 2, length: 5, count: 3))
                .contains("start: 2, length: 5")
        )

        #expect(description(.unexpectedPeripheral(Self.peripheral)).contains(Self.peripheral.uuid.uuidString))

        #expect(
            description(.allowDuplicatesInBackgroundNotSupported)
                .contains("allow duplicates")
        )

        #expect(
            description(.missingServiceIdentifiersInBackground)
                .contains("without specifying any service identifiers")
        )

        #expect(description(.stopped).contains("BLESwift stopped"))

        #expect(
            description(.backgroundRestorationInProgress)
                .contains("Background restoration is in progress")
        )

        #expect(
            description(.startupBackgroundTaskExpired)
                .contains("Startup background task expired")
        )

        #expect(
            description(.tooMuchData(expected: 4, received: Data([1, 2, 3, 4, 5])))
                .contains("expected: 4")
        )

        #expect(description(.timedOut).contains("Operation timed out"))

        #expect(description(.operationCancelled).contains("Operation cancelled"))

        #expect(
            description(.invalidStringEncoding)
                .contains("could not be decoded")
        )

        #expect(description(.alreadyScanning).contains("already in progress"))

        #expect(
            description(.readConflictsWithNotification)
                .contains("currently notifying")
        )

        #expect(description(.invalidArgument("bad timeout")).contains("bad timeout"))

        #expect(description(.l2capOpenFailed).contains("L2CAP channel failed"))

        #expect(description(.l2capChannelClosed).contains("L2CAP channel is closed"))
    }
}

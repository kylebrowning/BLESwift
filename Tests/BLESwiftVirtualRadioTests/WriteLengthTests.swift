//
//  WriteLengthTests.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftVirtualRadio
import Foundation
import Testing

/// Per-device `maximumWriteWithoutResponseLength` (#66): what a connected `Central` reports,
/// and what the radio drops, truncates, and still accepts against it.
@Suite("Per-device write length")
struct WriteLengthTests {

    @Test("A device registered with 100 reports it, drops a 101-byte write, and truncates a notification to it", .timeLimit(.minutes(1)))
    func perDeviceLength() async throws {
        let radio = VirtualRadio()
        let handler = RecordingHandler()
        let device = RecordingDevice.make(handler: handler, maximumWriteWithoutResponseLength: 100)
        let handle = await radio.register(device)

        let (central, _, _) = await RecordingDevice.central(on: radio, label: "WriteLengthTests.central")
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil))

        #expect(await peripheral.maximumWriteValueLength(for: .withoutResponse) == 100)
        #expect(await peripheral.maximumWriteValueLength(for: .withResponse) == VirtualRadio.maximumValueLength)

        // Oversize first, then exactly at the limit: the remote's serial chain keeps the two
        // in order, so once the 100-byte write has reached the handler the 101-byte one has
        // already been judged — and dropped.
        try await peripheral.write(Data(repeating: 0xAA, count: 101), to: RecordingDevice.control, type: .withoutResponse)
        try await peripheral.write(Data(repeating: 0xBB, count: 100), to: RecordingDevice.control, type: .withoutResponse)
        let arrived = await RecordingDevice.first(of: handler.writes)
        #expect(arrived?.count == 100)
        #expect(await handler.written.map(\.count) == [100])

        // `.withResponse` is held to the attribute maximum whatever the device's packet size.
        try await peripheral.write(Data(repeating: 0xCC, count: VirtualRadio.maximumValueLength), to: RecordingDevice.control)
        #expect(await handler.written.map(\.count) == [100, VirtualRadio.maximumValueLength])

        // A notification is one packet too: clipped to the device's length, not the radio's.
        let notifications = Task { () -> Data? in
            for try await value in peripheral.notifications(for: RecordingDevice.control) as AsyncThrowingStream<Data, Error> {
                return value
            }
            return nil
        }
        #expect(await RecordingDevice.first(of: handler.subscriptions) == true)
        await handle.notify(Data(repeating: 0x7F, count: 150), for: RecordingDevice.control, to: nil)
        #expect(try await notifications.value?.count == 100)
    }

    @Test("A device registered without a length reports the default")
    func defaultLength() async throws {
        let radio = VirtualRadio()
        let device = RecordingDevice.make(handler: RecordingHandler())
        await radio.register(device)

        let (central, _, _) = await RecordingDevice.central(on: radio, label: "WriteLengthTests.default")
        let peripheral = try await central.connect(PeripheralIdentifier(uuid: device.descriptor.identifier, name: nil))

        #expect(await peripheral.maximumWriteValueLength(for: .withoutResponse) == VirtualRadio.maximumWriteWithoutResponseLength)
        #expect(VirtualRadio.maximumWriteWithoutResponseLength == 182)
    }
}

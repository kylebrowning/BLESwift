//
//  RecordingDevice.swift
//  BLESwiftVirtualRadioTests
//

import BLESwift
import BLESwiftCore
import BLESwiftVirtualRadio
import Dispatch
import Foundation

/// A handler that records every write and subscription change that it receives and publishes each
/// on a stream. A test waits on the event instead of sleeping, and can assert afterward that
/// nothing else arrived.
actor RecordingHandler: VirtualDeviceHandler {

    /// The values of every write batch, in order of arrival.
    private(set) var written: [Data] = []

    /// Every subscription change, in order of arrival.
    private(set) var subscriptionLog: [(characteristic: CharacteristicIdentifier, isSubscribed: Bool)] = []

    /// Each value written, when it arrives.
    let writes: AsyncStream<Data>
    private let writesContinuation: AsyncStream<Data>.Continuation

    /// Each subscription change, when it arrives.
    let subscriptions: AsyncStream<Bool>
    private let subscriptionsContinuation: AsyncStream<Bool>.Continuation

    init() {
        (writes, writesContinuation) = AsyncStream.makeStream()
        (subscriptions, subscriptionsContinuation) = AsyncStream.makeStream()
    }

    func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
        .success(Data([0xD1]))
    }

    func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
        for entry in entries {
            written.append(entry.value)
            writesContinuation.yield(entry.value)
        }
        return .success(())
    }

    func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {
        subscriptionLog.append((characteristic, isSubscribed))
        subscriptionsContinuation.yield(isSubscribed)
    }
}

/// The fixture that every suite in this target shares: a heart-rate device with one static readable
/// characteristic and one dynamic characteristic. A central can write the dynamic characteristic
/// either way, and the device can notify it.
enum RecordingDevice {

    static let service = ServiceIdentifier(uuid: "180D")
    static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    static let control = CharacteristicIdentifier(uuid: "2A39", service: service)
    static let measurementValue = Data([0, 72])

    static let services = [
        GATTService(identifier: service, characteristics: [
            GATTCharacteristic(
                identifier: measurement,
                properties: [.read, .notify],
                permissions: [.readable],
                value: measurementValue
            ),
            GATTCharacteristic(
                identifier: control,
                properties: [.read, .write, .writeWithoutResponse, .notify],
                permissions: [.readable, .writeable]
            )
        ])
    ]

    /// A device under `identifier`, served by `handler`.
    static func make(
        identifier: UUID = UUID(),
        handler: any VirtualDeviceHandler,
        maximumWriteWithoutResponseLength: Int = VirtualRadio.maximumWriteWithoutResponseLength
    ) -> VirtualDevice {
        VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                name: "Recording HRM",
                advertisement: AdvertisementData(localName: "Recording HRM", serviceUUIDs: [service], isConnectable: true),
                services: services,
                maximumWriteWithoutResponseLength: maximumWriteWithoutResponseLength
            ),
            handler: handler
        )
    }

    /// A `Central` on a fresh `VirtualCentralBackend` over `radio`. The function waits until it is
    /// `.poweredOn`.
    static func central(on radio: VirtualRadio, label: String) async -> (central: Central, backend: VirtualCentralBackend, queue: DispatchQueue) {
        let queue = DispatchQueue(label: label)
        let backend = VirtualCentralBackend(radio: radio, queue: queue)
        let central = Central(backend: backend, queue: queue)
        await waitFor { central.state == .poweredOn }
        return (central, backend, queue)
    }

    /// Polls `condition` every 5 ms until it is `true` or `timeout` elapses. It covers what the
    /// public surface gives no event for: the backend reaching `.poweredOn`, and a synchronous
    /// radio table change that a test must see before it continues.
    static func waitFor(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Runs `body` on `queue` and returns its result. It does not block a cooperative thread.
    static func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Whether `central` currently holds `id` as connected. `ConnectionState` carries the
    /// `Peripheral` and is not `Equatable`, so tests use this function.
    static func isConnected(_ central: Central, _ id: PeripheralIdentifier) async -> Bool {
        if case .connected = await central.connectionState(of: id) { return true }
        return false
    }

    /// Whether `central` reports `id` as disconnected.
    static func isDisconnected(_ central: Central, _ id: PeripheralIdentifier) async -> Bool {
        if case .disconnected = await central.connectionState(of: id) { return true }
        return false
    }

    /// The first value that `stream` yields.
    static func first<Value>(of stream: AsyncStream<Value>) async -> Value? {
        for await value in stream { return value }
        return nil
    }

    /// The error that `body` throws, as an `NSError`, or `nil` if it does not throw.
    static func failure(of body: () async throws -> some Any) async -> NSError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as NSError
        }
    }
}

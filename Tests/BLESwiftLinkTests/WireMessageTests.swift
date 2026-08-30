//
//  WireMessageTests.swift
//  BLESwiftLinkTests
//

import BLESwiftCore
import BLESwiftLink
import Foundation
import Testing

@Suite("Wire messages")
struct WireMessageTests {

    private static let id = UUID()
    private static let service = ServiceIdentifier(uuid: "180D")
    private static let characteristic = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let descriptor = DescriptorIdentifier(uuid: "2902", characteristic: characteristic)
    private static let err = WireError(domain: "D", code: 3, description: "boom")

    /// Every `LinkMessage` case with a non-trivial payload. Extend when a case is added.
    static let samples: [LinkMessage] = [
        .clientHello(ClientHello(protocolVersion: 1, role: .central, clientName: "app")),
        .clientHello(ClientHello(protocolVersion: 1, role: .peripheral, clientName: "app", hostIdentifier: id)),
        .serverHello(ServerHello(protocolVersion: 1, accepted: false, reason: "old", providerName: "p")),
        .serverHello(ServerHello(protocolVersion: 1, accepted: true, reason: nil, providerName: "p", assignedHostIdentifier: id)),
        .centralRequest(.scan(services: ["180D"], allowDuplicates: true)),
        .centralRequest(.stopScan),
        .centralRequest(.connect(peripheral: id, options: WireConnectOptions(notifyOnConnection: true, notifyOnDisconnection: false, notifyOnNotification: true), requiresANCS: true)),
        .centralRequest(.cancelConnection(peripheral: id)),
        .centralRequest(.registerForConnectionEvents(services: nil, peripherals: [id])),
        .centralRequest(.unregisterForConnectionEvents),
        .centralRequest(.discoverServices(peripheral: id, services: nil)),
        .centralRequest(.discoverCharacteristics(peripheral: id, service: "180D", characteristics: ["2A37"])),
        .centralRequest(.readValue(peripheral: id, characteristic: WireCharacteristicRef(characteristic))),
        .centralRequest(.writeValue(peripheral: id, characteristic: WireCharacteristicRef(characteristic), value: Data([1, 2]), type: .withoutResponse, sequence: 9)),
        .centralRequest(.setNotifyValue(peripheral: id, characteristic: WireCharacteristicRef(characteristic), enabled: true)),
        .centralRequest(.discoverDescriptors(peripheral: id, characteristic: WireCharacteristicRef(characteristic))),
        .centralRequest(.readDescriptor(peripheral: id, descriptor: WireDescriptorRef(descriptor))),
        .centralRequest(.writeDescriptor(peripheral: id, descriptor: WireDescriptorRef(descriptor), value: Data([3]))),
        .centralRequest(.readRSSI(peripheral: id)),
        .centralRequest(.openL2CAPChannel(peripheral: id, psm: 0x81, channel: 4)),
        .centralRequest(.l2capData(channel: 4, data: Data([5]))),
        .centralRequest(.l2capCredit(channel: 4, bytes: 1024)),
        .centralRequest(.l2capClose(channel: 4)),
        .centralEvent(.didUpdateState(.poweredOn)),
        .centralEvent(.didDiscover(peripheral: id, name: "n", advertisement: WireAdvertisement(AdvertisementData(localName: "n", serviceUUIDs: [service], manufacturerData: Data([0xFF]), serviceData: [service: Data([1])], txPowerLevel: -4, isConnectable: true)), rssi: -40)),
        .centralEvent(.didConnect(peripheral: id, name: "n", maximumWriteWithResponse: 512, maximumWriteWithoutResponse: 182)),
        .centralEvent(.didFailToConnect(peripheral: id, error: err)),
        .centralEvent(.didDisconnect(peripheral: id, error: nil)),
        .centralEvent(.connectionEventDidOccur(peripheral: id, connected: false)),
        .centralEvent(.didUpdateANCSAuthorization(peripheral: id, authorized: true)),
        .centralEvent(.didDiscoverServices(peripheral: id, services: ["180D"], error: nil)),
        .centralEvent(.didDiscoverCharacteristics(peripheral: id, service: "180D", characteristics: [WireDiscoveredCharacteristic(uuid: "2A37", properties: 0x12)], error: nil)),
        .centralEvent(.didWriteValue(peripheral: id, characteristic: WireCharacteristicRef(characteristic), error: err)),
        .centralEvent(.writeWithoutResponseAccepted(peripheral: id, sequence: 9)),
        .centralEvent(.didUpdateValue(peripheral: id, characteristic: WireCharacteristicRef(characteristic), value: Data([7]), error: nil)),
        .centralEvent(.didUpdateNotificationState(peripheral: id, characteristic: WireCharacteristicRef(characteristic), isNotifying: true, error: nil)),
        .centralEvent(.didDiscoverDescriptors(peripheral: id, characteristic: WireCharacteristicRef(characteristic), descriptors: ["2902"], error: nil)),
        .centralEvent(.didUpdateValueForDescriptor(peripheral: id, descriptor: WireDescriptorRef(descriptor), value: nil, error: err)),
        .centralEvent(.didWriteValueForDescriptor(peripheral: id, descriptor: WireDescriptorRef(descriptor), error: nil)),
        .centralEvent(.didReadRSSI(peripheral: id, rssi: -61, error: nil)),
        .centralEvent(.didModifyServices(peripheral: id, invalidated: ["180D"])),
        .centralEvent(.didOpenL2CAPChannel(peripheral: id, channel: 4, psm: 0x81, error: nil)),
        .centralEvent(.l2capData(channel: 4, data: Data([6]))),
        .centralEvent(.l2capCredit(channel: 4, bytes: 2)),
        .centralEvent(.l2capClosed(channel: 4, error: err)),
        .hostRequest(.startAdvertising(localName: "rig", services: ["180D"])),
        .hostRequest(.stopAdvertising),
        .hostRequest(.addService(WireGATTService(GATTService(identifier: service, characteristics: [GATTCharacteristic(identifier: characteristic, properties: [.read, .notify], permissions: [.readable], value: Data([1]))])))),
        .hostRequest(.removeAllServices),
        .hostRequest(.respond(token: id, value: Data([1]), attError: nil)),
        .hostRequest(.respond(token: id, value: nil, attError: 3)),
        .hostRequest(.updateValue(sequence: 2, value: Data([8]), characteristic: WireCharacteristicRef(characteristic), centrals: [id])),
        .hostEvent(.didUpdateState(.poweredOff)),
        .hostEvent(.didStartAdvertising(error: nil)),
        .hostEvent(.didAddService(service: "180D", error: err)),
        .hostEvent(.didReceiveRead(WireReadRequest(token: id, central: WireSubscriber(id: id, maximumUpdateValueLength: 20), characteristic: WireCharacteristicRef(characteristic), offset: 0))),
        .hostEvent(.didReceiveWrite(WireWriteRequest(token: id, entries: [WireWriteEntry(central: WireSubscriber(id: id, maximumUpdateValueLength: 20), characteristic: WireCharacteristicRef(characteristic), offset: 2, value: Data([1]))]))),
        .hostEvent(.didSubscribe(central: WireSubscriber(id: id, maximumUpdateValueLength: 20), characteristic: WireCharacteristicRef(characteristic))),
        .hostEvent(.didUnsubscribe(central: WireSubscriber(id: id, maximumUpdateValueLength: 20), characteristic: WireCharacteristicRef(characteristic))),
        .hostEvent(.updateValueDelivered(sequence: 2)),
    ]

    @Test("Every message round-trips through every codec", arguments: LinkCodec.allCases)
    func roundTrip(codec: LinkCodec) throws {
        for sample in Self.samples {
            let data = try codec.encode(sample)
            let decoded = try codec.decode(LinkMessage.self, from: data)
            #expect(decoded == sample, "\(sample) via \(codec)")
        }
    }

    @Test("Every WireCentralState round-trips through every codec", arguments: LinkCodec.allCases)
    func centralStateRoundTrip(codec: LinkCodec) throws {
        for state in WireCentralState.allCases {
            let message = LinkMessage.centralEvent(.didUpdateState(state))
            #expect(try codec.decode(LinkMessage.self, from: codec.encode(message)) == message, "\(state)")
        }
    }

    @Test("Every WireWriteType round-trips through every codec", arguments: LinkCodec.allCases)
    func writeTypeRoundTrip(codec: LinkCodec) throws {
        for type in WireWriteType.allCases {
            let message = LinkMessage.centralRequest(.writeValue(
                peripheral: Self.id,
                characteristic: WireCharacteristicRef(Self.characteristic),
                value: Data([1]),
                type: type,
                sequence: 0
            ))
            #expect(try codec.decode(LinkMessage.self, from: codec.encode(message)) == message, "\(type)")
        }
    }

    @Test("Every LinkRole round-trips through every codec", arguments: LinkCodec.allCases)
    func linkRoleRoundTrip(codec: LinkCodec) throws {
        for role in LinkRole.allCases {
            let message = LinkMessage.clientHello(ClientHello(protocolVersion: 1, role: role, clientName: "app"))
            #expect(try codec.decode(LinkMessage.self, from: codec.encode(message)) == message, "\(role)")
        }
    }

    @Test("A client hello with no hostIdentifier decodes, leaving the field nil")
    func helloWithoutAHostIdentifierDecodes() throws {
        // Written by hand rather than by encoding a `ClientHello`: this is the shape a client
        // that predates the field puts on the wire, and it must still be readable.
        let json = Data(#"{"clientHello":{"_0":{"protocolVersion":1,"role":"peripheral","clientName":"old"}}}"#.utf8)
        let decoded = try LinkCodec.json.decode(LinkMessage.self, from: json)
        #expect(decoded == .clientHello(ClientHello(protocolVersion: 1, role: .peripheral, clientName: "old")))
        guard case .clientHello(let hello) = decoded else {
            Issue.record("expected a clientHello, got \(decoded)")
            return
        }
        #expect(hello.hostIdentifier == nil)
    }

    @Test("A server hello with no assignedHostIdentifier decodes, leaving the field nil")
    func serverHelloWithoutAnAssignedIdentifierDecodes() throws {
        // The shape a provider that predates the field puts on the wire; still readable.
        let json = Data(#"{"serverHello":{"_0":{"protocolVersion":1,"accepted":true,"providerName":"old"}}}"#.utf8)
        let decoded = try LinkCodec.json.decode(LinkMessage.self, from: json)
        #expect(decoded == .serverHello(ServerHello(protocolVersion: 1, accepted: true, reason: nil, providerName: "old")))
        guard case .serverHello(let hello) = decoded else {
            Issue.record("expected a serverHello, got \(decoded)")
            return
        }
        #expect(hello.assignedHostIdentifier == nil)
    }

    @Test("WireError ↔ NSError preserves domain, code, description")
    func errorConversion() {
        let ns = NSError(domain: "CBErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "timed out"])
        let wire = WireError(ns)
        #expect(wire == WireError(domain: "CBErrorDomain", code: 7, description: "timed out"))
        let back = wire.nsError
        #expect(back.domain == "CBErrorDomain")
        #expect(back.code == 7)
        #expect(back.localizedDescription == "timed out")
        let none: NSError? = nil
        #expect(none.wire == nil)
    }

    @Test("Advertisement round-trips through Core")
    func advertisement() throws {
        let original = AdvertisementData(localName: "n", serviceUUIDs: [Self.service], manufacturerData: Data([1]), serviceData: [Self.service: Data([2])], txPowerLevel: 3, isConnectable: false, overflowServiceUUIDs: [Self.service], solicitedServiceUUIDs: nil)
        let back = try WireAdvertisement(original).advertisementData
        #expect(back.localName == "n")
        #expect(back.serviceUUIDs == [Self.service])
        #expect(back.manufacturerData == Data([1]))
        #expect(back.serviceData?[Self.service] == Data([2]))
        #expect(back.txPowerLevel == 3)
        #expect(back.isConnectable == false)
        #expect(back.overflowServiceUUIDs == [Self.service])
        #expect(back.solicitedServiceUUIDs == nil)
    }

    @Test("GATT service, refs, subscribers, and requests round-trip through Core")
    func gattConversions() throws {
        let service = GATTService(identifier: Self.service, isPrimary: false, characteristics: [
            GATTCharacteristic(identifier: Self.characteristic, properties: [.write, .indicate], permissions: [.writeable], value: nil)
        ])
        #expect(try WireGATTService(service).gattService == service)
        #expect(try WireCharacteristicRef(Self.characteristic).identifier == Self.characteristic)
        #expect(try WireDescriptorRef(Self.descriptor).identifier == Self.descriptor)
        let subscriber = Subscriber(id: Self.id, maximumUpdateValueLength: 180)
        #expect(try WireSubscriber(subscriber).subscriber == subscriber)
        let read = ReadRequest(token: RequestToken(rawValue: Self.id), central: subscriber, characteristic: Self.characteristic, offset: 4)
        #expect(try WireReadRequest(read).readRequest == read)
        let write = WriteRequest(token: RequestToken(rawValue: Self.id), entries: [WriteRequest.Entry(central: subscriber, characteristic: Self.characteristic, offset: 0, value: Data([1]))])
        #expect(try WireWriteRequest(write).writeRequest == write)
        #expect(WireCentralState(.poweredOn).state == .poweredOn)
        #expect(WireWriteType(.withoutResponse).writeType == .withoutResponse)
        let options = WarningOptions(notifyOnConnection: true, notifyOnDisconnection: true, notifyOnNotification: false)
        let back = WireConnectOptions(options).warningOptions
        #expect(back.notifyOnConnection && back.notifyOnDisconnection && !back.notifyOnNotification)
    }
}

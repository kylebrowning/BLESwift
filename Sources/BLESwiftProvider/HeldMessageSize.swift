//
//  HeldMessageSize.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Foundation

/// What one message costs the provider while it is *held* rather than served — the accounting
/// behind ``PendingConnections/maximumQueuedBytes``.
///
/// This is a memory bound, not a wire measurement: it counts the variable-length payloads a
/// client can put on the wire, which are the only parts of a message it can make large, plus a
/// fixed overhead so a backlog of tiny messages is charged for too rather than being free.
extension LinkMessage {

    /// What every held message costs before its payload, standing in for the scalar fields
    /// and the array box the message itself occupies.
    static let heldOverhead = 64

    /// What holding this message costs against the provider's pre-handshake backlog cap.
    var heldByteCount: Int {
        LinkMessage.heldOverhead + heldPayloadByteCount
    }

    /// The bytes this message's variable-length fields keep alive.
    private var heldPayloadByteCount: Int {
        switch self {
        case .clientHello(let hello):
            return hello.clientName.utf8.count
        case .centralRequest(let request):
            return request.heldPayloadByteCount
        case .hostRequest(let request):
            return request.heldPayloadByteCount
        // A provider is never sent an event or a server hello. One that arrived would be
        // routed to the handshake and refused there, so it is only ever charged the overhead.
        case .serverHello, .centralEvent, .hostEvent:
            return 0
        }
    }
}

extension CentralRequest {

    /// The bytes this request's variable-length fields keep alive.
    var heldPayloadByteCount: Int {
        switch self {
        case .scan(let services, _):
            return LinkMessage.byteCount(of: services)
        case .registerForConnectionEvents(let services, let peripherals):
            return LinkMessage.byteCount(of: services) + LinkMessage.byteCount(of: peripherals)
        case .discoverServices(_, let services):
            return LinkMessage.byteCount(of: services)
        case .discoverCharacteristics(_, _, let characteristics):
            return LinkMessage.byteCount(of: characteristics)
        case .writeValue(_, _, let value, _, _):
            return value.count
        case .writeDescriptor(_, _, let value):
            return value.count
        case .l2capData(_, let data):
            return data.count
        // Everything else is a handful of scalars and identifiers, which the overhead covers.
        case .stopScan, .connect, .cancelConnection, .unregisterForConnectionEvents, .readValue,
             .setNotifyValue, .discoverDescriptors, .readDescriptor, .readRSSI, .openL2CAPChannel,
             .l2capCredit, .l2capClose:
            return 0
        }
    }
}

extension HostRequest {

    /// The bytes this request's variable-length fields keep alive.
    var heldPayloadByteCount: Int {
        switch self {
        case .startAdvertising(let localName, let services):
            return (localName?.utf8.count ?? 0) + LinkMessage.byteCount(of: services)
        case .addService(let service):
            return service.heldPayloadByteCount
        case .respond(_, let value, _):
            return value?.count ?? 0
        case .updateValue(_, let value, _, let centrals):
            return value.count + LinkMessage.byteCount(of: centrals)
        case .stopAdvertising, .removeAllServices:
            return 0
        }
    }
}

extension WireGATTService {

    /// The bytes this service's UUID strings and characteristic values keep alive.
    var heldPayloadByteCount: Int {
        uuid.utf8.count + characteristics.reduce(0) { $0 + $1.uuid.utf8.count + ($1.value?.count ?? 0) }
    }
}

extension LinkMessage {

    /// The bytes an optional list of UUID strings keeps alive.
    fileprivate static func byteCount(of strings: [String]?) -> Int {
        strings?.reduce(0) { $0 + $1.utf8.count } ?? 0
    }

    /// The bytes an optional list of identifiers keeps alive — sixteen apiece, a `UUID`'s
    /// whole storage.
    fileprivate static func byteCount(of identifiers: [UUID]?) -> Int {
        (identifiers?.count ?? 0) * 16
    }
}
#endif

//
//  HeldMessageSize.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftLink
import Foundation

/// What one message costs the provider while it *holds* the message and does not serve it. This
/// is the accounting for ``PendingConnections/maximumQueuedBytes``.
///
/// This is a memory bound, not a wire measurement. It counts the variable-length payloads, which
/// are the only parts of a message that a client can make large. It adds a fixed overhead, so a
/// backlog of small messages is not free.
extension LinkMessage {

    /// What every held message costs before its payload: the scalar fields and the array box.
    static let heldOverhead = 64

    /// What this message costs against the provider's backlog cap before the handshake.
    var heldByteCount: Int {
        LinkMessage.heldOverhead + heldPayloadByteCount
    }

    /// The bytes that the variable-length fields of this message keep alive.
    private var heldPayloadByteCount: Int {
        switch self {
        case .clientHello(let hello):
            return hello.clientName.utf8.count
        case .centralRequest(let request):
            return request.heldPayloadByteCount
        case .hostRequest(let request):
            return request.heldPayloadByteCount
        // A client never sends an event or a server hello. If one arrives, the handshake refuses
        // it, so it costs only the overhead.
        case .serverHello, .centralEvent, .hostEvent:
            return 0
        }
    }
}

extension CentralRequest {

    /// The bytes that the variable-length fields of this request keep alive.
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
        // Each other request is a few scalars and identifiers. The overhead covers them.
        case .stopScan, .connect, .cancelConnection, .unregisterForConnectionEvents, .readValue,
             .setNotifyValue, .discoverDescriptors, .readDescriptor, .readRSSI, .openL2CAPChannel,
             .l2capCredit, .l2capClose:
            return 0
        }
    }
}

extension HostRequest {

    /// The bytes that the variable-length fields of this request keep alive.
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

    /// The bytes that the UUID strings and characteristic values of this service keep alive.
    var heldPayloadByteCount: Int {
        uuid.utf8.count + characteristics.reduce(0) { $0 + $1.uuid.utf8.count + ($1.value?.count ?? 0) }
    }
}

extension LinkMessage {

    /// The bytes that an optional list of UUID strings keeps alive.
    fileprivate static func byteCount(of strings: [String]?) -> Int {
        strings?.reduce(0) { $0 + $1.utf8.count } ?? 0
    }

    /// The bytes that an optional list of identifiers keeps alive. A `UUID` takes 16 bytes.
    fileprivate static func byteCount(of identifiers: [UUID]?) -> Int {
        (identifiers?.count ?? 0) * 16
    }
}
#endif

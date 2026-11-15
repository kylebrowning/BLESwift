//
//  L2CAPPublishing.swift
//  BLESwiftCore
//

/// A ``PeripheralManaging`` backend that can publish L2CAP channels. It mirrors the L2CAP
/// methods of `CBPeripheralManager`.
///
/// This capability is a separate protocol, so ``PeripheralManaging`` keeps its requirements.
/// `PeripheralHost` checks for it with `as?`. If the backend does not conform, a publish fails.
///
/// - Important: The delivery contract of ``PeripheralManaging`` applies to each event that this
///   protocol causes. Deliver every event asynchronously, on the serial queue of the backend.
public protocol L2CAPPublishing: PeripheralManaging {

    /// Publishes an L2CAP channel and lets the backend select the PSM. Mirrors
    /// `CBPeripheralManager.publishL2CAPChannel(withEncryption:)`. One
    /// `PeripheralHostEvent/didPublishL2CAPChannel(psm:error:)` event follows each call. The
    /// events arrive in call order.
    func publishL2CAPChannel(requiresEncryption: Bool)

    /// Removes the L2CAP channel that is published on `psm`. Mirrors
    /// `CBPeripheralManager.unpublishL2CAPChannel(_:)`. It takes BLESwift's ``L2CAPPSM`` and not
    /// CoreBluetooth's `CBL2CAPPSM`. One
    /// `PeripheralHostEvent/didUnpublishL2CAPChannel(psm:error:)` event follows each call.
    func unpublishL2CAPChannel(_ psm: L2CAPPSM)
}

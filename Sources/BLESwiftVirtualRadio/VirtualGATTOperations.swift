//
//  VirtualGATTOperations.swift
//  BLESwiftVirtualRadio
//

/// The GATT operations an injected ATT error applies to — the argument of
/// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
///
/// Each is a distinct ATT request on hardware, so a peripheral can refuse one and serve the
/// others: a characteristic that reads fine until it is written, or that subscribes only
/// once encrypted. `subscribe` covers the CCCD write behind both enabling and disabling
/// notifications.
public struct VirtualGATTOperations: OptionSet, Sendable, Hashable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// A read of the characteristic's value.
    public static let read = VirtualGATTOperations(rawValue: 1 << 0)

    /// A `.withResponse` write of the characteristic's value. A `.withoutResponse` write has
    /// no ATT response to carry an error, so it is never affected.
    public static let write = VirtualGATTOperations(rawValue: 1 << 1)

    /// The CCCD write that enables or disables notifications.
    public static let subscribe = VirtualGATTOperations(rawValue: 1 << 2)

    /// Every operation.
    public static let all: VirtualGATTOperations = [.read, .write, .subscribe]
}

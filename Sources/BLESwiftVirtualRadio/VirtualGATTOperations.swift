//
//  VirtualGATTOperations.swift
//  BLESwiftVirtualRadio
//

/// The GATT operations that an injected ATT error applies to.
/// Use it as the argument of ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
///
/// Each operation is a distinct ATT request on hardware, so a peripheral can refuse one and serve
/// the others. For example, a characteristic can allow reads but refuse writes. `subscribe` covers
/// the CCCD write that enables notifications and the one that disables them.
public struct VirtualGATTOperations: OptionSet, Sendable, Hashable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// A read of the characteristic's value.
    public static let read = VirtualGATTOperations(rawValue: 1 << 0)

    /// A `.withResponse` write of the characteristic's value. A `.withoutResponse` write has no ATT
    /// response to carry an error, so an injected error never affects it.
    public static let write = VirtualGATTOperations(rawValue: 1 << 1)

    /// The CCCD write that enables or disables notifications.
    public static let subscribe = VirtualGATTOperations(rawValue: 1 << 2)

    /// Every operation.
    public static let all: VirtualGATTOperations = [.read, .write, .subscribe]
}

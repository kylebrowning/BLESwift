//
//  SystemConnectionEvent.swift
//  BLESwiftCore
//

/// A system-level connection event for a peripheral matched by
/// `Central.connectionEventRegistration(services:peripherals:)` — delivered when the
/// peripheral connects to or disconnects from the *system* (by any app, or the Bluetooth
/// settings pane), not just through this `Central`.
///
/// Mirrors `centralManager(_:connectionEventDidOccur:for:)`. Not available on macOS.
public struct SystemConnectionEvent: Sendable, Equatable {

    /// Whether the peripheral connected to or disconnected from the system. Mirrors
    /// `CBConnectionEvent`.
    public enum Kind: Sendable, Equatable {
        /// The peripheral connected to the system.
        case peerConnected
        /// The peripheral disconnected from the system.
        case peerDisconnected
    }

    /// The peripheral the event concerns.
    public let peripheral: PeripheralIdentifier

    /// What happened.
    public let kind: Kind

    /// Creates a `SystemConnectionEvent`.
    public init(peripheral: PeripheralIdentifier, kind: Kind) {
        self.peripheral = peripheral
        self.kind = kind
    }
}

//
//  SystemConnectionEvent.swift
//  BLESwiftCore
//

/// A system-level connection event for a peripheral that
/// `Central.connectionEventRegistration(services:peripherals:)` matched. The system delivers it
/// when the peripheral connects to, or disconnects from, the *system*. Any app or the Bluetooth
/// settings pane can cause it, not only this `Central`.
///
/// Mirrors `centralManager(_:connectionEventDidOccur:for:)`. It is not available on macOS.
public struct SystemConnectionEvent: Sendable, Equatable {

    /// Whether the peripheral connected to the system or disconnected from it. Mirrors
    /// `CBConnectionEvent`.
    public enum Kind: Sendable, Equatable {
        /// The peripheral connected to the system.
        case peerConnected
        /// The peripheral disconnected from the system.
        case peerDisconnected
    }

    /// The peripheral that the event concerns.
    public let peripheral: PeripheralIdentifier

    /// What happened.
    public let kind: Kind

    /// Creates a `SystemConnectionEvent`.
    public init(peripheral: PeripheralIdentifier, kind: Kind) {
        self.peripheral = peripheral
        self.kind = kind
    }
}

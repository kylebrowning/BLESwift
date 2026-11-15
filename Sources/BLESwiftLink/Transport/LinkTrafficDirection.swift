//
//  LinkTrafficDirection.swift
//  BLESwiftLink
//

/// The direction of one message that ``LinkConnection/onTraffic`` reports.
public enum LinkTrafficDirection: Sendable {
    /// The connection received the message from the remote end.
    case inbound
    /// The connection sends the message to the remote end.
    case outbound
}

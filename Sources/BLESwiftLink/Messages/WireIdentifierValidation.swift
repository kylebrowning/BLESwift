//
//  WireIdentifierValidation.swift
//  BLESwiftLink
//

import Foundation

/// The reason why BLESwift could not convert a message from the wire into BLESwift types.
///
/// A link peer is not trusted input. A frame can decode cleanly and still carry a field that no
/// BLESwift type can represent. The code rejects each such field. Both ends treat the rejection
/// as a protocol violation. The provider closes the connection that sent the field. A client
/// drops its session and reconnects.
public enum WireDecodingError: Error, Equatable, Sendable {

    /// A UUID string that BLESwift identifiers do not accept. The case carries the string
    /// unchanged.
    case invalidIdentifier(String)

    /// Two UUID strings in the same keyed collection that name the same identifier after
    /// normalization. An example is `"180d"` and `"180D"`. The case carries the normalized form
    /// on which they collide.
    ///
    /// A well-formed peer never sends this, because an identifier is the key of the collections
    /// where it can occur. The frame is invented or corrupt, and the code must reject it. A
    /// dictionary that is built from colliding keys traps.
    case duplicateIdentifier(String)

    /// A negotiated maximum payload length of zero or less. No CoreBluetooth stack can report
    /// this length, and no caller can use it. The case carries the length unchanged. See
    /// ``WireLengthValidation``.
    case invalidMaximumLength(Int)

    /// A negative attribute offset. No CoreBluetooth stack can report it, and no caller can slice
    /// a payload at it. The case carries the offset unchanged. See ``WireLengthValidation``.
    case invalidOffset(Int)
}

/// A copy of the BLESwift identifiers' UUID rule, applied at the wire boundary.
///
/// `ServiceIdentifier`, `CharacteristicIdentifier`, and `DescriptorIdentifier` **trap** on a
/// string that they cannot normalize. `CBUUID(string:)` does the same. This is correct for a
/// programming error in an app. It is wrong for bytes from a socket, because a peer that sends
/// `"zz"` would stop the process on the end that decoded it.
///
/// Thus the code checks every string that crosses the wire. A string that fails the check causes
/// a thrown ``WireDecodingError/invalidIdentifier(_:)``. The code copies the rule and does not
/// share it, because the `BLESwiftCore` normalizer is internal and does not throw on purpose. A
/// table-driven test keeps the two rules the same.
///
/// **The rule.** A valid string is one of these:
///
/// - A 4-character (16-bit) or 8-character (32-bit) string of ASCII hex digits.
/// - A 36-character dashed 128-bit string. The dashes are at indices 8, 13, 18 and 23. Every
///   other character is an ASCII hex digit.
///
/// Case does not matter. No other string is valid.
public enum WireIdentifierValidation {

    /// Whether `uuid` is a string that BLESwift identifiers accept.
    ///
    /// - Parameter uuid: The candidate UUID string, as it arrived on the wire.
    /// - Returns: `true` if it is safe to pass the string to a BLESwift identifier.
    public static func isValid(_ uuid: String) -> Bool {
        switch uuid.count {
        case 4, 8:
            return uuid.allSatisfy(isASCIIHexDigit)
        case 36:
            let dashPositions: Set<Int> = [8, 13, 18, 23]
            for (index, character) in uuid.enumerated() {
                if dashPositions.contains(index) {
                    guard character == "-" else { return false }
                } else {
                    guard isASCIIHexDigit(character) else { return false }
                }
            }
            return true
        default:
            return false
        }
    }

    /// Returns `uuid` unchanged, after it checks that the string is safe to pass to a BLESwift
    /// identifier.
    ///
    /// - Parameter uuid: The candidate UUID string, as it arrived on the wire.
    /// - Returns: The same string.
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)`` if BLESwift identifiers do not accept
    ///   `uuid`.
    @discardableResult
    public static func validated(_ uuid: String) throws -> String {
        guard isValid(uuid) else { throw WireDecodingError.invalidIdentifier(uuid) }
        return uuid
    }

    /// Whether `character` is a single ASCII hex digit (`0`-`9`, `A`-`F`, `a`-`f`).
    ///
    /// This function does not use `Character.isHexDigit`, which accepts "hex digit" code points
    /// outside ASCII.
    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: // '0'-'9', 'A'-'F', 'a'-'f'
            return true
        default:
            return false
        }
    }
}

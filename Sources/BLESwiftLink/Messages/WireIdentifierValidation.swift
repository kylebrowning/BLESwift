//
//  WireIdentifierValidation.swift
//  BLESwiftLink
//

import Foundation

/// Why a message that arrived on the wire could not be turned into the BLESwift types it
/// stands for.
///
/// A link peer is not trusted input: a frame decodes cleanly and still carries a field no
/// BLESwift type can represent. Every such field is rejected here rather than passed on, and
/// both ends treat the rejection as a protocol violation — the provider closes the offending
/// connection, and a client drops its session and reconnects.
public enum WireDecodingError: Error, Equatable, Sendable {

    /// A UUID string that is not one BLESwift's identifiers accept, carried verbatim.
    case invalidIdentifier(String)
}

/// The wire boundary's copy of the UUID rule BLESwift's identifiers enforce.
///
/// `ServiceIdentifier`, `CharacteristicIdentifier`, and `DescriptorIdentifier` normalize the
/// string they are given and **trap** on one they cannot — the same thing `CBUUID(string:)`
/// does, and the right answer for a programming error in an app. It is the wrong answer for
/// bytes that arrived over a socket: a peer that sends `"zz"` would take the process down on
/// whichever end decoded it.
///
/// So the rule is checked here first, on every string that crosses the wire, and a string
/// that fails becomes a thrown ``WireDecodingError/invalidIdentifier(_:)`` instead of a trap.
/// The rule is replicated rather than shared because `BLESwiftCore`'s own normalizer is
/// internal to it and deliberately non-throwing; a table-driven test pins the two to each
/// other.
///
/// **The rule.** A 4-character (16-bit) or 8-character (32-bit) string of ASCII hex digits,
/// or a 36-character dashed 128-bit string whose dashes sit at indices 8, 13, 18 and 23 and
/// whose every other character is an ASCII hex digit. Case is irrelevant. Nothing else.
public enum WireIdentifierValidation {

    /// Whether `uuid` is a string BLESwift's identifiers accept.
    ///
    /// - Parameter uuid: The candidate UUID string, as it arrived on the wire.
    /// - Returns: `true` if passing it to a BLESwift identifier is safe.
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

    /// Returns `uuid` unchanged once it is known to be safe to hand to a BLESwift identifier.
    ///
    /// - Parameter uuid: The candidate UUID string, as it arrived on the wire.
    /// - Returns: The same string.
    /// - Throws: ``WireDecodingError/invalidIdentifier(_:)`` if `uuid` is not one BLESwift's
    ///   identifiers accept.
    @discardableResult
    public static func validated(_ uuid: String) throws -> String {
        guard isValid(uuid) else { throw WireDecodingError.invalidIdentifier(uuid) }
        return uuid
    }

    /// Whether `character` is a single ASCII hex digit (`0`-`9`, `A`-`F`, `a`-`f`).
    ///
    /// Deliberately not `Character.isHexDigit`, which is Unicode-aware and accepts "hex
    /// digit" code points outside ASCII that the identifiers themselves reject.
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

//
//  UUIDNormalization.swift
//  BLESwiftCore
//

/// Normalizes a Bluetooth UUID string to the canonical form ``ServiceIdentifier`` and
/// ``CharacteristicIdentifier`` store, matching `CBUUID(string:).uuidString`'s own
/// normalization exactly (verified by a parity test in `IdentifierTests` against real
/// `CBUUID`).
///
/// Accepts three forms — a 4-character (16-bit), 8-character (32-bit), or 36-character
/// dashed (128-bit) hex UUID string, hex digits in either case — and returns the uppercase
/// form (dashes preserved, positions unchanged). Traps on anything else, mirroring
/// `CBUUID(string:)`'s own behavior of raising an exception for a string that "does not
/// represent a valid UUID".
///
/// - Parameter uuid: The UUID string to normalize.
/// - Returns: The normalized, uppercase UUID string.
func normalizedUUIDString(_ uuid: String) -> String {
    switch uuid.count {
    case 4, 8:
        guard uuid.allSatisfy(isASCIIHexDigit) else {
            preconditionFailure("String \(uuid) does not represent a valid UUID")
        }
        return uuid.uppercased()

    case 36:
        let dashPositions: Set<Int> = [8, 13, 18, 23]
        for (index, character) in uuid.enumerated() {
            if dashPositions.contains(index) {
                guard character == "-" else {
                    preconditionFailure("String \(uuid) does not represent a valid UUID")
                }
            } else {
                guard isASCIIHexDigit(character) else {
                    preconditionFailure("String \(uuid) does not represent a valid UUID")
                }
            }
        }
        return uuid.uppercased()

    default:
        preconditionFailure("String \(uuid) does not represent a valid UUID")
    }
}

/// Whether `character` is a single ASCII hex digit (`0`-`9`, `A`-`F`, `a`-`f`).
///
/// Deliberately not `Character.isHexDigit` — that stdlib property is Unicode-aware and
/// accepts non-ASCII "hex digit" code points (e.g. fullwidth forms) that `CBUUID(string:)`
/// itself rejects; this stays byte-for-byte faithful to CoreBluetooth's own, ASCII-only
/// parsing.
private func isASCIIHexDigit(_ character: Character) -> Bool {
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

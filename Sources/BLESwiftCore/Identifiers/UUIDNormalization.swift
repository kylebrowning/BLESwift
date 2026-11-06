//
//  UUIDNormalization.swift
//  BLESwiftCore
//

/// Normalizes a Bluetooth UUID string to the canonical form that ``ServiceIdentifier`` and
/// ``CharacteristicIdentifier`` store. It matches `CBUUID(string:).uuidString` exactly. A parity
/// test in `IdentifierTests` verifies this against a real `CBUUID`.
///
/// It accepts three forms of hex UUID string, with hex digits in either case.
/// - 4 characters (16-bit)
/// - 8 characters (32-bit)
/// - 36 characters with dashes (128-bit)
///
/// It returns the uppercase form, with the dashes unchanged. It traps on any other input, where
/// `CBUUID(string:)` raises an exception for a string that "does not represent a valid UUID".
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
/// This function deliberately does not use `Character.isHexDigit`. That property is
/// Unicode-aware and accepts non-ASCII "hex digit" code points (for example, fullwidth forms) that
/// `CBUUID(string:)` rejects. This function matches CoreBluetooth's ASCII-only parsing.
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

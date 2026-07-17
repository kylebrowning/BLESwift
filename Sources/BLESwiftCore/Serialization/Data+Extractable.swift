//
//  Data+Extractable.swift
//  BLESwiftCore
//

import Foundation

extension Data {

    /// Reads a range of this `Data` and reinterprets it as `T`.
    ///
    /// Uses an unaligned load (`loadUnaligned(fromByteOffset:as:)`), so `T` may be read
    /// starting at any byte offset regardless of its natural alignment requirement.
    /// A naive implementation using `UnsafeRawBufferPointer`'s aligned load would trap at
    /// runtime on a misaligned offset — this cannot.
    ///
    /// - Parameters:
    ///   - start: The starting byte offset of the range to read.
    ///   - length: The number of bytes to read from `start`. Must equal
    ///     `MemoryLayout<T>.size`, or this throws.
    /// - Throws: ``BLESwiftError/dataOutOfBounds(start:length:count:)`` if `start` is
    ///   negative, `length` is not positive, `length` does not equal
    ///   `MemoryLayout<T>.size`, or the range `[start, start + length)` falls outside
    ///   `self`'s bounds. The bounds check is overflow-safe: it never computes
    ///   `start + length` when comparing against `count`, so a pathological `start` or
    ///   `length` cannot wrap around and defeat the check.
    /// - Returns: The bytes at `[start, start + length)`, reinterpreted as `T`.
    public func extract<T: BitwiseCopyable>(start: Int, length: Int) throws -> T {
        guard
            start >= 0,
            length > 0,
            length == MemoryLayout<T>.size,
            count - start >= length
        else {
            throw BLESwiftError.dataOutOfBounds(start: start, length: length, count: count)
        }

        return withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: start, as: T.self)
        }
    }
}

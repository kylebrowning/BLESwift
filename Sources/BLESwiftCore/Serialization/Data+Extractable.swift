//
//  Data+Extractable.swift
//  BLESwiftCore
//

import Foundation

extension Data {

    /// Reads a range of this `Data` and reinterprets it as `T`.
    ///
    /// It uses an unaligned load (`loadUnaligned(fromByteOffset:as:)`), so it can read `T` from any
    /// byte offset, whatever `T`'s alignment. The bounds check is overflow-safe and never computes
    /// `start + length`.
    ///
    /// - Parameters:
    ///   - start: The starting byte offset of the range to read.
    ///   - length: The number of bytes to read from `start`. It must equal `MemoryLayout<T>.size`,
    ///     or this function throws.
    /// - Throws: ``BLESwiftError/dataOutOfBounds(start:length:count:)`` in these cases:
    ///   - `start` is negative.
    ///   - `length` is not positive.
    ///   - `length` does not equal `MemoryLayout<T>.size`.
    ///   - The range `[start, start + length)` is outside `self`.
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

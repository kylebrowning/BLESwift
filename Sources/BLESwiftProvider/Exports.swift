//
//  Exports.swift
//  BLESwiftProvider
//

/// Re-exports `BLESwiftVirtualRadio` from `BLESwiftProvider`, so the virtual radio types
/// (`VirtualRadio`, `VirtualDevice`, `VirtualCentralBackend`, …) stay visible through a plain
/// `import BLESwiftProvider` after moving into their own module.
@_exported import BLESwiftVirtualRadio

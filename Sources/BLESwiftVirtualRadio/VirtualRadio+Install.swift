//
//  VirtualRadio+Install.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCompat17
import BLESwiftCore
import Foundation

extension VirtualRadio {

    /// Everything mutable, guarded by one lock.
    private struct InstallState {
        var radio: VirtualRadio?
    }

    private static let installState = Mutex(InstallState())

    /// Routes every subsequently-constructed `Central()` / `PeripheralHost()` to `radio`
    /// (`PeripheralHost` exists on iOS and macOS only).
    ///
    /// A single call at launch is enough to point an app's default-initialized instances at an
    /// in-process radio instead of CoreBluetooth — for UI tests, previews or demo builds, on
    /// device or in the simulator, with no provider and no TCP:
    ///
    /// ```swift
    /// import BLESwiftVirtualRadio
    ///
    /// #if DEBUG
    /// let radio = VirtualRadio()
    /// // ... register devices on `radio` ...
    /// VirtualRadio.install(radio)
    /// #endif
    /// ```
    ///
    /// This must run before the app's first `Central()` / `PeripheralHost()`: those default
    /// initializers consult `BackendRegistry` once, at construction, so installing after one
    /// has already been built has no effect on it.
    ///
    /// `BackendRegistry` has one slot per backend kind, so `VirtualRadio.install` and
    /// `SimulatorLink.install` replace each other, and ``installed`` reports only what *this*
    /// type last did — it does not notice a later `SimulatorLink.install` taking the slot.
    /// `Central(backend: VirtualCentralBackend(radio:queue:), queue:)` bypasses the registry
    /// entirely and is preferred in unit tests, where a process-global is a liability.
    ///
    /// Idempotent: calling this again simply replaces the registered factories and ``installed``.
    ///
    /// The registry and ``installed`` change together: both factories go in through
    /// `BackendRegistry.setFactories(central:peripheralManager:)`, one lock acquisition,
    /// from inside this type's own state lock — so no `Central()`, `PeripheralHost()`, or
    /// ``installed`` read on another thread can see a radio-backed central next to the
    /// previous peripheral factory, or a registry already routing to the radio while
    /// ``installed`` still says `nil`. The lock order is this state, then the registry's; the
    /// registry never takes this lock.
    public static func install(_ radio: VirtualRadio) {
        installState.withLock { state in
            BackendRegistry.setFactories(
                central: { queue in VirtualCentralBackend(radio: radio, queue: queue) },
                peripheralManager: { queue in VirtualPeripheralManagerBackend(radio: radio, queue: queue) }
            )
            state.radio = radio
        }
    }

    /// Reverts `Central()` / `PeripheralHost()` to their default `CoreBluetooth` backend.
    ///
    /// Clears both `BackendRegistry` factories and ``installed``. Idempotent; safe to call
    /// even when nothing is installed.
    ///
    /// The registry slot is cleared whoever filled it: after a later `SimulatorLink.install`,
    /// this removes the link's routing too (and `SimulatorLink.isInstalled` does not notice).
    /// Use one installer per process.
    ///
    /// Cleared the way ``install(_:)`` sets them: both factories and ``installed`` under the
    /// same lock, so nothing can observe one gone and the other still routing.
    public static func uninstall() {
        installState.withLock { state in
            BackendRegistry.setFactories(central: nil, peripheralManager: nil)
            state.radio = nil
        }
    }

    /// The radio ``install(_:)`` registered, or `nil` when none is installed.
    public static var installed: VirtualRadio? {
        installState.withLock { $0.radio }
    }
}

//
//  VirtualRadio+Install.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCompat17
import BLESwiftCore
import Foundation

extension VirtualRadio {

    /// The state that one lock guards.
    private struct InstallState {
        var radio: VirtualRadio?
    }

    private static let installState = Mutex(InstallState())

    /// Routes every `Central()` and `PeripheralHost()` that the app constructs later to `radio`.
    /// `PeripheralHost` exists on iOS and macOS only. Use it for UI tests, previews, or demo
    /// builds. It works on a device and in the simulator, with no provider and no TCP.
    ///
    /// - Call it before the app's first `Central()` or `PeripheralHost()`. The default initializers
    ///   read `BackendRegistry` once, so an existing instance does not change.
    /// - `BackendRegistry` has one slot for each backend kind, so this call and
    ///   `SimulatorLink.install` replace each other. ``installed`` reports only what this type did
    ///   last.
    /// - The call is idempotent. A second call replaces the factories and ``installed``.
    /// - In unit tests, use `Central(backend:queue:)` with a ``VirtualCentralBackend``. It does not
    ///   use the registry.
    ///
    /// The registry and ``installed`` change together. The code takes this type's state lock and
    /// then the registry's lock, and the registry never takes this type's lock. See
    /// <doc:InProcessMocking#Route-your-app-to-the-radio>.
    public static func install(_ radio: VirtualRadio) {
        installState.withLock { state in
            BackendRegistry.setFactories(
                central: { queue in VirtualCentralBackend(radio: radio, queue: queue) },
                peripheralManager: { queue in VirtualPeripheralManagerBackend(radio: radio, queue: queue) }
            )
            state.radio = radio
        }
    }

    /// Reverts `Central()` and `PeripheralHost()` to their default `CoreBluetooth` backend.
    ///
    /// This call clears both `BackendRegistry` factories and ``installed``. It is idempotent, and
    /// safe when nothing is installed.
    ///
    /// The call clears the registry slot, whoever filled it. After a later `SimulatorLink.install`,
    /// it also removes the link's routing, and `SimulatorLink.isInstalled` does not show this. Use
    /// one installer for each process.
    ///
    /// Like ``install(_:)``, it clears both factories and ``installed`` under one lock, so no
    /// thread sees one cleared while the other still routes.
    public static func uninstall() {
        installState.withLock { state in
            BackendRegistry.setFactories(central: nil, peripheralManager: nil)
            state.radio = nil
        }
    }

    /// The radio that ``install(_:)`` registered, or `nil` if no radio is installed.
    public static var installed: VirtualRadio? {
        installState.withLock { $0.radio }
    }
}

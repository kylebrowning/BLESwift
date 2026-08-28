# ``BLESwiftLink``

The wire protocol shared by the simulator-side backends and the host-side provider.

## Overview

`BLESwiftLink` defines the framed, `Codable` messages that carry BLESwift's backend seam
(`CentralManaging`, `PeripheralRemote`, `PeripheralManaging`) across a localhost TCP
connection, plus the transport primitives and the declarative fixture format both ends use.
Most apps never import it directly — see ``BLESwiftSimulatorLink`` and ``BLESwiftProvider``.

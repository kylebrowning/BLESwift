# ``BLESwiftLink``

The wire protocol shared by the simulator-side backends and the host-side provider.

## Overview

`BLESwiftLink` defines the framed, `Codable` messages that carry BLESwift's backend seam
(`CentralManaging`, `PeripheralRemote`, `PeripheralManaging`) across a localhost TCP
connection, plus the transport primitives and the declarative fixture format both ends use.
Most apps never import it directly — see `BLESwiftSimulatorLink` and `BLESwiftProvider`.

## Topics

### Endpoints and codecs

- ``LinkEndpoint``
- ``LinkCodec``
- ``LinkProtocol``
- ``LinkRole``
- ``LinkError``

### Transport

- ``LinkConnection``
- ``LinkListener``
- ``LinkListenerError``
- ``LinkFraming``
- ``LinkFramingError``
- ``LinkFlowControl``

### Handshake

- ``ClientHello``
- ``ServerHello``

### Messages

- ``LinkMessage``
- ``CentralRequest``
- ``CentralWireEvent``
- ``HostRequest``
- ``HostWireEvent``

### Wire types

- ``WireAdvertisement``
- ``WireCentralState``
- ``WireCharacteristicRef``
- ``WireConnectOptions``
- ``WireDescriptorRef``
- ``WireDiscoveredCharacteristic``
- ``WireError``
- ``WireGATTCharacteristic``
- ``WireGATTService``
- ``WireReadRequest``
- ``WireSubscriber``
- ``WireWriteEntry``
- ``WireWriteRequest``
- ``WireWriteType``

### Fixtures

- ``FixtureDocument``
- ``FixtureDevice``
- ``FixtureService``
- ``FixtureCharacteristic``
- ``FixtureProperty``
- ``FixturePermission``

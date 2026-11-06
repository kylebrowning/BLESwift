# ``BLESwiftLink``

The wire protocol shared by the simulator-side backends and the host-side provider.

## Overview

`BLESwiftLink` defines the wire protocol between a simulator app and a host provider. The messages are framed and `Codable`. They carry BLESwift's backend seam (`CentralManaging`, `PeripheralRemote`, `PeripheralManaging`) across a localhost TCP connection.

The module also has the transport primitives and the declarative fixture format. Both ends of the link use them.

Most apps do not import this module. Use `BLESwiftSimulatorLink` in the app and `BLESwiftProvider` on the host.

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

### Trust boundary

- ``WireIdentifierValidation``
- ``WireLengthValidation``
- ``WireDecodingError``

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

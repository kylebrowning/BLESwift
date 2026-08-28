# ``BLESwiftProvider``

The host-side provider that serves BLE to simulator apps.

## Overview

`BLESwiftProvider` accepts link connections and serves them from the Mac's real Bluetooth
radio (passthrough), from an in-process virtual radio hosting fixture or code-defined
devices, or both. The `bleswift-provider` executable is a thin command-line front end over
``Provider``; depend on this library directly to host virtual devices written in Swift.

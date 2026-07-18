# Regenerating the GATT assigned-numbers tables

The lookup tables in `Sources/BLESwiftCore/AssignedNumbers/GATTAssignedNumbers+*.swift`
(`serviceNames`, `characteristicNames`, `descriptorNames`) are derived from the **Bluetooth
SIG's public assigned-numbers dataset**. They are checked-in generated data — regenerate them
whenever the SIG publishes new assignments.

## Source of truth

The SIG maintains the canonical assigned numbers as YAML in its public repository:

- Services: `assigned_numbers/uuids/service_uuids.yaml`
- Characteristics: `assigned_numbers/uuids/characteristic_uuids.yaml`
- Descriptors: `assigned_numbers/uuids/descriptors.yaml`

Public mirror (no auth required):
`https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/uuids/`

Each YAML entry looks like:

```yaml
uuids:
  - uuid: 0x180D
    name: Heart Rate
    id: org.bluetooth.service.heart_rate
```

## Procedure

1. Fetch the three YAML files from the URL above (or clone the `bluetooth-SIG/public` repo).
2. For each file, emit one Swift dictionary entry per `uuid`/`name` pair, keyed by the 16-bit
   value as a `UInt16` literal:

   ```
   0x180D: "Heart Rate",
   ```

   A tiny transform does the whole job — for example, with `yq` + `awk`:

   ```sh
   BASE=https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/uuids
   curl -s "$BASE/service_uuids.yaml" \
     | yq -r '.uuids[] | "        0x\(.uuid | sub("0x";"") | upcase): \"\(.name)\","'
   ```

   (Repeat for `characteristic_uuids.yaml` and `descriptors.yaml`.)
3. Paste the emitted lines into the `static let …Names` dictionary in the matching
   `GATTAssignedNumbers+{Services,Characteristics,Descriptors}.swift` file, keeping the
   `GENERATED FILE` header.
4. Keys are 16-bit `UInt16` values. The lookup layer
   (`GATTAssignedNumbers.assignedNumber(forNormalizedUUID:)`) collapses a full
   `0000XXXX-0000-1000-8000-00805F9B34FB` Base-UUID down to its 16-bit `XXXX` before indexing,
   so a peripheral that reports a well-known attribute in expanded 128-bit form still resolves.
5. `swift build --build-tests` (zero warnings) and
   `swift test --skip-build --filter GATTAssignedNumbers`.

## Vendor UUIDs (not from the SIG dataset)

`vendorServiceNames` / `vendorCharacteristicNames` hold a small, hand-maintained set of
widely-deployed **non-SIG** 128-bit UUIDs (e.g. the Nordic UART Service) that have no 16-bit
assigned number. These are keyed by full **uppercase** UUID string and are curated by hand —
they are not part of the SIG regeneration above. Add to them sparingly.

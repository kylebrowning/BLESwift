# Two-simulator BLE end-to-end test

`Scripts/sim-to-sim-e2e.sh` runs the whole BLESwift stack across **two iOS Simulators** with
no Bluetooth hardware and no entitlements:

```
iPhone "advertiser"                       iPhone "scanner"
  BLESwiftExplorer                          BLESwiftExplorer
  PeripheralHost (180D)                     Central.scan(services: [180D])
        │                                          │
        └──────── BLESwiftSimulatorLink ───────────┘
                          │  TCP 127.0.0.1:45541
                  bleswift-provider (no --passthrough)
                       VirtualRadio
```

Both apps call `SimulatorLink.install()` at startup, so their `Central` / `PeripheralHost`
are served by the host-side `bleswift-provider` instead of CoreBluetooth. The provider runs
**without** `--passthrough`, so the two apps meet on its in-process virtual radio and never
touch a real radio.

## Running it

```sh
Scripts/sim-to-sim-e2e.sh
```

Environment overrides:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ADVERTISER_SIM` | `iPhone 17 Pro` | Simulator that hosts the peripheral |
| `SCANNER_SIM` | `iPhone 17` | Simulator that scans |
| `ADVERTISER_READY_TIMEOUT` | `900` | Seconds to wait for the advertiser flow to pass |

**The port is fixed at 45541** and the script has no knob for it. The Explorer resolves its
endpoint from `BLESWIFT_LINK` or `LinkEndpoint.default` (`127.0.0.1:45541`), and the runner
offers no way to put an environment variable in front of the app under test — `grantiva run`
takes launch *arguments* only, and `SIMCTL_CHILD_*` reaches a `simctl launch` the runner never
performs — so a provider on any other port would simply never be dialed. It used to be a
`PORT` variable that quietly did nothing; see friction item #10.

The script:

1. Ensures both simulators exist and are booted (idempotent — it looks each one up by name
   and creates it only if missing).
2. Builds and starts `bleswift-provider`, waiting for its `listening on …` line.
3. Builds `BLESwiftExplorer` **once** for the simulator into `.build/e2e-dd`, and installs the
   same `.app` on both simulators via `grantiva run --app-file`.
4. Runs the advertiser flow in the background with `--keep-alive`, polling its
   `.build/e2e-report/advertiser/report.json` for `"status": "passed"`
   (≤ `ADVERTISER_READY_TIMEOUT`, default 900 s, logging elapsed time every 10 s). The bound
   is that wide because a cold runner pays grantiva's agent build inside it — see friction
   item #11.
5. Runs the scanner flow in the foreground.
6. Exits with the scanner's status; the `trap` reaps the provider, the keep-alive grantiva
   process, and the runner processes it strands.

Reports land in `.build/e2e-report/{advertiser,scanner}` (grantiva writes `report.json`,
`report.html`, JUnit XML, Allure results and failure screenshots there); the provider's stdout
is `.build/e2e-report/provider.log`.

## Provisioning the second simulator

Only one simulator normally exists on a fresh machine. The second one was created with:

```sh
xcrun simctl create "iPhone 17" "iPhone 17"
xcrun simctl boot "iPhone 17"
```

If the plain device-type name is not accepted, spell out the identifiers:

```sh
xcrun simctl list devicetypes | grep 'iPhone 17'
xcrun simctl list runtimes | grep iOS
xcrun simctl create "iPhone 17" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
    com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

The script does this itself (picking the newest available iOS runtime), so you should not have
to run it by hand.

## When it fails on CI

The `sim-to-sim-e2e` job on `macos-latest` uses `iPhone 16 Pro` / `iPhone 16`. First things to
check when it goes red:

- **grantiva installation.** `brew install grantiva/tap/grantiva` must succeed, and the first
  `grantiva run` extracts and builds an embedded WebDriverAgent runner — several minutes, and
  it needs a usable Xcode. `grantiva doctor` in a debug step reports what is missing.
- **Simulator availability.** If neither `iPhone 16 Pro` nor `iPhone 16` exists on the runner
  image, the script creates them from the newest installed iOS runtime; if no iOS runtime is
  installed at all it fails immediately with `no available iOS runtime`.
- **Port 45541 already bound** by something else on the runner.
- **Uploaded artifacts.** The `sim-to-sim-e2e` artifact contains `provider.log` (which side
  connected: `opened central session …` / `opened host session …`), both `report.json`s and
  grantiva's failure screenshots. That is usually enough to tell a BLE failure from a UI one.

## grantiva friction log

Everything below was observed against **grantiva 1.6.5** on macOS 27 / Xcode 27 beta 6 /
iOS 27.0 simulators while building this test. It is written for grantiva's maintainer.

### 1. Launch arguments arrive with an extra leading dash

The brief's Maestro syntax `arguments: ["--auto-advertise"]` is **rejected** —
`Error: validation failed with 1 error(s)` — so the map form is mandatory:

```yaml
- launchApp:
    arguments:
      "--auto-advertise": true
```

That form is accepted and the flow passes… but the app never sees the flag. `ps` on the
running app under grantiva shows what actually got passed:

```
…/BLESwiftExplorer.app/BLESwiftExplorer ---auto-advertise true
```

Three dashes. The runner prepends a `-` to every key (the Maestro `-key value` convention),
so a key that already starts with `--` becomes `---`. The workaround in `advertise.yaml` is to
write the key with **one** dash, `"-auto-advertise": true`, which reaches the app as
`--auto-advertise true`.

*Wish:* pass the key through verbatim when it already begins with `-`, or document the
prepending. And the failure is silent — the flow passed while the app ran with a mangled flag.

### 2. `visible:` silently drops `id` when `text` is also given

The brief's assertion

```yaml
- extendedWaitUntil:
    visible:
      id: "advertise.status"
      text: "Advertising"
```

is echoed by the runner as `extendedWaitUntil: visible text="Advertising"` — the `id` is gone.
Confirmed by substituting a deliberately bogus id: with `id: "totally.bogus.identifier"` **and**
`text: "Advertising"` the step still passes, while the same bogus id **alone** fails after the
timeout (so id matching itself works, and works well — it is only ignored in combination).

*Wish:* AND the two selectors, or at minimum warn that one was discarded.

### 3. `text:` matching is case-insensitive and unanchored

`text: "Advertising"` matched the app's then-current **"Not advertising"** idle label.
Combined with (1), the advertiser flow passed for two full runs while nothing was advertising
at all — the provider log showed no `opened host session` line. `text: "^Advertising$"` works,
and so does removing the collision: `AdvertiseView`'s idle label is now **"Idle"**, so the
plain `text: "Advertising"` assertion in `advertise.yaml` can only be satisfied by the positive
state.

*Wish:* an `exact:`/`caseSensitive:` selector, or at least a documented default. A test that
passes because the *negative* label matched is the worst kind of green.

### 4. No readiness signal for a `--keep-alive` session

A keep-alive session is exactly the tool for "hold app A in state X while I drive app B", but
the only way to know the flow finished is to poll the report. `report.json` is rewritten
incrementally (it carries an `updateSeq`), so its mere existence is not a verdict — the script
polls for a top-level `"status": "passed"` and treats `running`/`pending` as keep-waiting.

*Wish:* `--ready-file <path>` (touched when the flow completes), or a line on stdout that is
guaranteed to be flushed, or `grantiva run --keep-alive --json` emitting one NDJSON record per
completed flow.

### 5. Killing `grantiva run` strands its children, and the strays hold the simulator

`kill -INT` on a backgrounded `grantiva run --keep-alive` (the documented "Release with
Ctrl-C") does not take down the `grantiva-runner` child or the WebDriverAgent
`xcodebuild test-without-building` it started. They survive, and the next run against that
simulator fails with:

```
Error: Simulator <UDID> is already owned by another Grantiva run.
Use `grantiva simulator ensure --name <unique-name>` and pass that simulator,
or wait for the active run to finish.
```

…while `grantiva simulator sessions` says *"No Grantiva-managed simulator sessions."* and
`~/.grantiva/simulator-capacity/sessions.json` is `[]`. So the ownership check and the session
ledger disagree: ownership is inferred from the live processes, which nothing had cleaned up.
`grantiva runner stop` reports "No active session found." and does not help either. The script
therefore reaps by pattern, per UDID:

```sh
pkill -f "grantiva-runner .*--device $udid"
pkill -f "test-without-building .*-destination id=$udid"
pkill -f "simctl diagnose .*--udid=$udid"
```

(That last one matters too: each killed WDA `xcodebuild` leaves a `simctl diagnose` collecting
a 600 s log bundle.)

*Wish:* SIGINT/SIGTERM on `grantiva run` should tear down the whole process group; and
`grantiva simulator teardown` should have a `--udid`/`--force` mode that releases an
ownership claim whose owner is gone. Today `--session-id` is useless when the ledger is empty.

### 6. Intermittent `Failed to create session for app: <bundle id>`

Hit three times in ~15 runs, always immediately after a previous session had been killed:
`launchApp` fails in 460 ms with `Failed to create session for app: com.bleswift.explorer` and
every later step is skipped. `grantiva runner stop` + a few seconds' wait cleared it every
time. Probably the same stale-state family as (5).

*Wish:* retry once, or say which precondition failed (agent port busy? WDA session already
open?).

### 7. Concurrent sessions on two different simulators: **works**

Confirmed, and it is what makes this test possible: a backgrounded `grantiva run --keep-alive`
on `iPhone 17 Pro` and a foreground `grantiva run` on `iPhone 17` coexist happily, each with
its own GrantivaAgent port (8540 / 8731). The only sharp edge is (5): the two runs must target
different simulators, and the first one's strays must be reaped before that simulator is used
again.

### 8. Provisioning a second simulator by name

`grantiva simulator ensure --name … --device-type … --runtime …` exists but requires all three,
so it is no shorter than `xcrun simctl create` and does not accept the friendly device-type
name (`"iPhone 17"`) the way `simctl` does. The script uses `simctl` directly.

*Wish:* `grantiva simulator ensure --name "iPhone 17"` alone — resolve the device type from the
name and the runtime to the newest installed — would be a genuinely nice one-liner for CI.

### 9. Off-screen elements are not found, and `scrollUntilVisible` is the fix

`tapOn: id="scan.startHeartRate"` failed with `Element not found` purely because the button sat
below the fold of a SwiftUI `List`; the accessibility tree does not expose it until it is
scrolled in. `scrollUntilVisible: { element: { id: … }, direction: DOWN }` handles it and is in
both flows now. Worth calling out in the docs — it is the single most confusing failure mode
for someone whose selector is provably correct.

### 10. Small things

- **No way to set an environment variable on the app under test.** `launchApp` takes
  *arguments* only, and the runner launches through its own agent rather than
  `simctl launch`, so `SIMCTL_CHILD_*` never reaches the app either. Anything the app reads
  from the environment — here `BLESWIFT_LINK`, which is how a build is pointed at a
  non-default provider endpoint — is therefore unreachable from a flow, and the host-side
  service has to sit on the port the app already defaults to. An `env:` map on `launchApp`
  (or passing the runner's own environment through) would close this.
- `grantiva run --flow <path>` copies the flow into a temp dir and reports failures against
  that temp path (`/var/folders/…/grantiva-<UUID>/advertise.yaml`), which is noise when you are
  trying to open the file you wrote.
- The summary table is printed twice per run (once per flow, once per device), which makes CI
  logs harder to scan than they need to be.
- Failure screenshots go to `.grantiva/captures/` in the working directory even when
  `--report-dir` is given; only the copies inside the report dir are useful to CI, and the
  stray `.grantiva/` directory has to be gitignored.

### 11. No warm-up step: every cold run pays the 5-10 minute agent build

The first `grantiva run` on a machine builds `GrantivaAgent` ("This may take 5-10 minutes" in
its own output) and then a WebDriverAgent runner (~65 s), all *inside* the first flow's
execution — nothing has run a step yet, and no progress reaches the caller. On CI that is the
whole cost of the job, paid again on every run, and it was what first blew this script's
advertiser-readiness bound.

*Wish:* a warm-up command that does only that work and exits (`grantiva runner install
--prebuild`, say), so CI can run it as its own step and see it fail as its own step. And a
documented cache location for the built agent and runner, so `actions/cache` can restore them
between runs instead of rebuilding from scratch each time.

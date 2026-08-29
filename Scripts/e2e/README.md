# Two-simulator BLE end-to-end test

`Scripts/sim-to-sim-e2e.sh` runs the whole BLESwift stack across **two iOS Simulators** with
no Bluetooth hardware and no entitlements:

```
iPhone "advertiser"                       iPhone "scanner"
  BLESwiftExplorer                          BLESwiftExplorer
  PeripheralHost (180D)                     Central.scan(services: [180D])
        │                                          │
        └──────── BLESwiftSimulatorLink ───────────┘
                          │  TCP 127.0.0.1:<ephemeral>
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
| `ADVERTISER_READY_TIMEOUT` | `900` | Seconds to wait for the advertiser flow to finish |

**Nothing is pinned to a port.** The provider is started with `--listen 127.0.0.1:0`, so the
system picks; the provider names the *bound* port on its (line-buffered) `listening on …`
line, the script reads it back from there, and both `grantiva run` invocations get
`--env BLESWIFT_LINK=127.0.0.1:<port>`. The Explorer resolves its endpoint through
`SimulatorLink.install()` → `LinkEndpoint.fromEnvironment()`, so both simulators dial exactly
the provider this run started, and a port already in use on the machine cannot collide with it.

The script:

1. Ensures both simulators exist and are booted, with
   `grantiva simulator ensure --name <name> --json` — find-or-create, boots by default, and
   reports the UDID that every downstream command takes.
2. Builds and starts `bleswift-provider` on an ephemeral loopback port, waiting for its
   `listening on …` line and parsing the port out of it.
3. Builds `BLESwiftExplorer` **once** for the simulator into `.build/e2e-dd`, and installs the
   same `.app` on both simulators with `simctl install` before either session starts.
4. Runs the advertiser flow in the background with `--keep-alive` and
   `--ready-file .build/e2e-report/advertiser.ready`, waiting for that file (≤
   `ADVERTISER_READY_TIMEOUT`, default 900 s, logging elapsed time every 10 s) and then
   requiring its `"status"` to be `passed`.
5. Runs the scanner flow in the foreground.
6. Exits with the scanner's status; the `trap` reaps the provider and runs
   `grantiva simulator teardown --udid <UDID> --force` for each simulator.

Reports land in `.build/e2e-report/{advertiser,scanner}` (grantiva writes `report.json`,
`report.html`, JUnit XML, Allure results and failure screenshots there); the provider's stdout
is `.build/e2e-report/provider.log`.

## Provisioning the second simulator

Nothing to do by hand: `grantiva simulator ensure --name "iPhone 17"` resolves the device type
from the name and the newest installed iOS runtime, creates the simulator if it is missing,
reuses it if it is not, and boots it either way. A machine that already has two simulators
sharing a name is fine too — `ensure` reports one UDID and every downstream command is given
that UDID rather than the name, so a duplicate cannot make a run ambiguous.

## When it fails on CI

The `sim-to-sim-e2e` job on `macos-latest` resolves `ADVERTISER_SIM` / `SCANNER_SIM` at run
time — the two newest distinct `iPhone …` names the runner image actually has, taken from
`xcrun simctl list devices available -j`. Nothing is pinned, because named devices drift with
the image's Xcode and a name that matches nothing fails the job outright.

**grantiva is installed unpinned.** `grantiva/homebrew-tap` ships a single `Formula/grantiva.rb`
with no versioned formulae, so the job takes whatever the tap's HEAD points at. The script
depends on 1.7.0 features (`simulator ensure --name`, `run --ready-file`, `run --env`,
`simulator teardown --udid --force`), so the job prints `grantiva --version` as its own step.

The job is `continue-on-error: true`, but not because the flow cannot pass — it has. It is
non-gating because GitHub macOS runner capacity is erratic: simulator boots on that image have
been measured anywhere from 109 s to 577 s.

First things to check when it goes red:

- **grantiva version.** The `grantiva version` step; anything below 1.7.0 will fail on the
  flags above.
- **grantiva installation.** `brew install grantiva/tap/grantiva` must succeed, and on a cold
  machine the first `grantiva run` builds `GrantivaAgent` and a WebDriverAgent runner inside
  the first flow's clock. `grantiva doctor` reports what is missing.
- **Simulator availability.** If no iOS runtime is installed at all, `grantiva simulator ensure`
  has nothing to create the device from and the script fails immediately.
- **Uploaded artifacts.** The `sim-to-sim-e2e` artifact contains `provider.log` (which side
  connected: `opened central session …` / `opened host session …`), both `report.json`s and
  grantiva's failure screenshots. That is usually enough to tell a BLE failure from a UI one.

## grantiva notes

### Resolved in grantiva 1.7.0

Twelve friction items were logged against **1.6.5** while this test was built, and 1.7.0
closed all but one of them. Kept here as history, one line each, with what the script and the
flows now do instead:

1. **Launch arguments arrived with an extra leading dash.** `"--auto-advertise"` reached the
   app as `---auto-advertise`, so the flow wrote the key with one dash. 1.7.0 passes a key
   through verbatim when it already begins with `-`; `advertise.yaml` is back to
   `"--auto-advertise": true`.
2. **`visible:` silently dropped `id` when `text` was also given.** The advertiser assertion
   had to drop the identifier. 1.7.0 ANDs the two; `id: advertise.status` is back alongside
   `text: "Advertising"`.
3. **`text:` matching was unanchored and case-insensitive**, so `"Advertising"` matched the
   app's `"Not advertising"` idle label and the flow passed while nothing advertised. 1.7.0
   has `exact: true`, which both flows now use — and `AdvertiseView`'s idle label, renamed to
   `"Idle"` to dodge the collision, reads `"Not advertising"` again.
4. **No readiness signal for a `--keep-alive` session**, so the script polled the
   incrementally-rewritten `report.json`. 1.7.0 has `run --ready-file <path>`, written once and
   atomically after every flow reaches a terminal state; the script waits on that file and
   reads its `"status"`.
5. **Killing `grantiva run` stranded its children** — a `grantiva-runner`, a WebDriverAgent
   `xcodebuild test-without-building` and a `simctl diagnose` — and the strays kept the
   simulator "owned by another Grantiva run" while the session ledger said it was free. The
   script reaped them by `pkill` pattern. 1.7.0 has
   `simulator teardown --udid <UDID> --force`, which reclaims by live process inspection and
   reconciles the registry; the `pkill` block and the `grantiva runner stop` call are gone.
6. **Intermittent `Failed to create session for app: <bundle id>`**, always right after a
   previous session had been killed. Not seen since; presumed to have gone with (5), since it
   was the same stale-ownership family.
7. **Concurrent sessions on two different simulators work.** Not a problem then and not one
   now — it is what makes this test possible.
8. **`simulator ensure` required `--name`, `--device-type` and `--runtime` together**, so the
   script used `xcrun simctl` and its own JSON lookup. 1.7.0 accepts `--name` alone and reads
   the device type out of the name; the simctl lookup is gone.
9. **Off-screen elements are not found, and `scrollUntilVisible` is the fix.** Not a bug — the
   accessibility tree genuinely does not expose a `List` row below the fold. Both flows keep
   their `scrollUntilVisible` steps.
10. **No way to set an environment variable on the app under test**, which forced the provider
    onto the port the app already defaulted to (45541). 1.7.0 has `run --env KEY=VALUE`; the
    provider now binds an ephemeral port and both sessions are given
    `--env BLESWIFT_LINK=127.0.0.1:<port>`. Two smaller notes from the same item — flows being
    reported against their temp-dir copy, and the summary table being printed twice — are
    cosmetic and unchanged. The third, failure screenshots landing in a stray `.grantiva/` in
    the working directory, is fixed: a run with `--report-dir` now writes only there, and the
    `.gitignore` entry for `.grantiva/` has been removed.
11. **Every cold run paid the 5–10 minute `GrantivaAgent` build** inside the first flow's
    execution, with no progress reaching the caller. Still true on a genuinely cold machine —
    see the open item below — but 1.7.0 caches the built agent and WebDriverAgent per runtime,
    so it is paid once rather than per run.
12. **WebDriverAgent's 90-second startup timeout** was what made this job `continue-on-error`.
    With the simulator booted to `bootstatus -b` and the app pre-installed, and with 1.7.0's
    WDA cache, it has not been hit again; the job stays non-gating for runner capacity, not
    for this.

### Open

**Cold-runner first-run WebDriverAgent build.** grantiva's WDA cache covers iOS 26.2 and 26.4.
GitHub's `macos-latest` image is on 26.2, so CI should now be served from that cache; a local
machine on iOS 27 falls outside it and rebuilds WebDriverAgent once, the first time a flow runs
against a 27 simulator. Nothing to work around — it is a one-time cost per runtime — but it is
the remaining reason a first run looks hung for a few minutes.

**`simulator ensure` prints prose, not a UDID.** Without `--json` it prints
`Reused iPhone 17 Pro (<UDID>) — Booted`, so a script that wants the UDID has to either scrape
that line or ask for `--json` (which the script does). Worth a mention in the help text, whose
summary reads as though the bare command hands back the identifier.

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

## Running it on CI

**On every push to `main` and every same-repository pull request** — `.github/workflows/sim-to-sim-e2e.yml`,
on the project's self-hosted Mac runner (labels `self-hosted, macOS, ARM64, bleswift`). It
is a PR gate now because the machine boots two simulators in seconds; GitHub's hosted macOS
image took 112 s to 577 s and flaked on runner weather, which is why the job was on-demand
only until the runner moved. The job's `if:` skips a pull request from a fork — but that
condition lives in the workflow file, and a fork's PR runs its own copy of it, so it is a
convenience rather than the boundary. The boundary is the repository's fork-PR approval
policy plus the rule in `ci.yml`: approving a fork PR includes reading its
`.github/workflows` diff. It
**fails honestly** when it fails — there is no `continue-on-error`. grantiva is whatever the
runner has installed (`brew upgrade grantiva` on the Mac to move it); the job prints the
version it ran.

It can also be dispatched from the Actions tab. The dispatch form takes two optional inputs,
`advertiser_sim` and `scanner_sim`. Give both to
pin the run to particular simulator names; leave both empty — the default — and the job uses
two CI-only devices, `BLESwift CI Advertiser` and `BLESwift CI Scanner`, created on first use
by `Scripts/ci/ensure-ci-simulator.sh` from the newest iPhone device type on the highest-version
iOS runtime installed. A device of that name on an older runtime, or left unavailable by a
runtime removal, is deleted and recreated — so the CI devices follow runtime installs — and a
delete that fails stops the job rather than creating a duplicate of the name. The runner is also a
workstation, and the job's reclaim step tears down every device of the names it used — so
the names are CI's own, never "the two newest iPhones" someone is debugging on. Giving only
one of the two inputs, or the same name twice, is refused with a readable error rather than
silently running both roles on one device.

**grantiva is whatever the runner has.** The job installs nothing: it puts Homebrew on
`PATH` and runs the grantiva already on the Mac, printing `grantiva --version` as its own
step. The script depends on 1.7.0 features (`simulator ensure --name`, `run --ready-file`,
`run --env`, `simulator teardown --udid --force`); `brew upgrade grantiva` on the runner moves
it, and the tap has no versioned formulae to pin to.

First things to check when a run goes red:

- **grantiva version.** The `grantiva version` step; anything below 1.7.0 will fail on the
  flags above.
- **grantiva presence.** A missing grantiva fails the `grantiva version` step with
  `command not found` — `brew install grantiva/tap/grantiva` on the runner. On a cold
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
12. **WebDriverAgent's 90-second startup timeout** was what first made this job non-gating.
    With the simulator booted to `bootstatus -b` and the app pre-installed, and with 1.7.0's
    WDA cache, it has not been hit again.

### Open

**Cold-runner first-run WebDriverAgent build.** grantiva's WDA cache covers iOS 26.2 and 26.4.
A machine on iOS 27 — the self-hosted runner included — falls outside it and rebuilds
WebDriverAgent once, the first time a flow runs against a 27 simulator. Nothing to work around —
it is a one-time cost per runtime on the runner — but it is the remaining reason a first run
looks hung for a few minutes.

**`simulator ensure --name` refuses a duplicated name.** A machine with two simulators of the
same name gets `Multiple simulators are named "<name>"; delete duplicates or use a unique
name` and a non-zero exit — and GitHub's runner image ships three "iPhone 17 Pro Max" devices,
so a name the runner picks can genuinely be ambiguous. There is no `--udid` on `ensure` to
disambiguate with, and deleting a runner's devices is not this script's business, so
`ensure_simulator` catches that one error and falls back to `xcrun simctl list devices
available -j`: it picks a device of that name (preferring one already booted), boots it, and
logs a warning. Everything downstream already runs by UDID, so nothing else changes. The
fallback goes away the day `ensure` accepts a UDID or picks a device itself.

**`simulator ensure` prints prose, not a UDID.** Without `--json` it prints
`Reused iPhone 17 Pro (<UDID>) — Booted`, so a script that wants the UDID has to either scrape
that line or ask for `--json` (which the script does). Worth a mention in the help text, whose
summary reads as though the bare command hands back the identifier.

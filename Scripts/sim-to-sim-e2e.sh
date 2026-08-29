#!/usr/bin/env bash
#
# Two-simulator BLE end-to-end test.
#
# One simulator advertises as "BLESwift Explorer Sim" (180D) and a second one
# scans and must find it. Neither simulator has Bluetooth: both Explorer apps
# route Central/PeripheralHost through the host-side `bleswift-provider`, which
# runs WITHOUT `--passthrough`, so the two apps meet on the provider's virtual
# radio. No hardware, no entitlements.
#
# Usage: Scripts/sim-to-sim-e2e.sh
#   ADVERTISER_SIM   simulator name for the peripheral  (default "iPhone 17 Pro")
#   SCANNER_SIM      simulator name for the central     (default "iPhone 17")
#   ADVERTISER_READY_TIMEOUT
#                    seconds to wait for the advertiser flow to pass (default 900)
#
# The provider binds an ephemeral port (`--listen 127.0.0.1:0`); the bound port is
# read back from its listening line and handed to both apps as
# `--env BLESWIFT_LINK=127.0.0.1:<port>`, which `SimulatorLink.install()` resolves
# through `LinkEndpoint.fromEnvironment()`. Nothing is pinned, so a port already in
# use on the machine cannot collide with this run.
#
# See Scripts/e2e/README.md.

set -euo pipefail

ADVERTISER_SIM="${ADVERTISER_SIM:-iPhone 17 Pro}"
SCANNER_SIM="${SCANNER_SIM:-iPhone 17}"
# Generous by default: on a cold runner grantiva builds its agent (5-10 minutes by its own
# log) and a WebDriverAgent runner before the flow's first step ever runs, and that build is
# paid inside this wait. The CI job's own 25-minute cap is the real backstop.
ADVERTISER_READY_TIMEOUT="${ADVERTISER_READY_TIMEOUT:-900}"
BUNDLE_ID="com.bleswift.explorer"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REPORT_ROOT=".build/e2e-report"
ADVERTISER_REPORT="$REPORT_ROOT/advertiser"
SCANNER_REPORT="$REPORT_ROOT/scanner"
PROVIDER_LOG="$REPORT_ROOT/provider.log"
ADVERTISER_LOG="$REPORT_ROOT/advertiser-session.log"
ADVERTISER_READY_FILE="$REPORT_ROOT/advertiser.ready"

PROVIDER_PID=""
ADVERTISER_PID=""
ADVERTISER_UDID=""
SCANNER_UDID=""

# stderr, so a `log` inside a function whose stdout is being captured (see
# `ensure_simulator`) cannot end up glued to the value that function returns.
log() { printf '\n==> %s\n' "$*" >&2; }

cleanup() {
    local status=$?
    log "Tearing down"
    if [[ -n "$ADVERTISER_PID" ]] && kill -0 "$ADVERTISER_PID" 2>/dev/null; then
        # The keep-alive session holds the runner open; SIGINT is the documented
        # release ("Release with Ctrl-C").
        kill -INT "$ADVERTISER_PID" 2>/dev/null || true
        sleep 3
        kill -9 "$ADVERTISER_PID" 2>/dev/null || true
    fi
    # Killing `grantiva run` can strand its `grantiva-runner` child, the WebDriverAgent
    # `xcodebuild test-without-building` and a `simctl diagnose` log collection, and the
    # strays keep the simulator "owned by another Grantiva run". `teardown --udid --force`
    # reclaims one device by live process inspection: it kills exactly that trio, breaks
    # the lease and reconciles the session registry.
    for udid in "$ADVERTISER_UDID" "$SCANNER_UDID"; do
        [[ -n "$udid" ]] || continue
        grantiva simulator teardown --udid "$udid" --force >/dev/null 2>&1 || true
        xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    if [[ -n "$PROVIDER_PID" ]] && kill -0 "$PROVIDER_PID" 2>/dev/null; then
        # TERM first, so the provider's own handler runs `stop()` and closes its sessions;
        # SIGKILL only if it is still there three seconds later.
        kill "$PROVIDER_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6; do
            kill -0 "$PROVIDER_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$PROVIDER_PID" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

# --- Simulators -------------------------------------------------------------
# `grantiva simulator ensure --name <name>` is find-or-create: it reuses a simulator of that
# name if one exists, and otherwise creates it from the device type read out of the name and
# the newest installed iOS runtime. It boots by default and reports the UDID, which is what
# every downstream command takes — so a machine that happens to have two simulators sharing a
# name can never make this run ambiguous.
#
# `--json`, not the plain output: without it `ensure` prints a human sentence
# ("Reused iPhone 17 Pro (<UDID>) — Booted") that would have to be scraped.
#
# One case `ensure` refuses outright: a machine with two simulators of the same name, which it
# answers with `Multiple simulators are named "<name>"; delete duplicates or use a unique
# name`. GitHub's runner image ships three "iPhone 17 Pro Max" devices, so this is not
# hypothetical. Deleting a runner's devices is not this script's business, so the duplicate is
# resolved here instead: pick one device of that name out of `simctl list devices available`,
# preferring one already booted, and carry on by UDID — which is what every command past this
# point takes anyway. Warned about, never silent.
duplicate_named_udid() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
matches = [d for runtime in devices for d in devices[runtime] if d["name"] == name]
booted = [d for d in matches if d.get("state") == "Booted"]
chosen = (booted or matches)
print(chosen[0]["udid"] if chosen else "")
' "$1"
}

ensure_simulator() {
    local name="$1"
    local start=$SECONDS
    local udid output errors status errors_file
    # stderr kept apart from stdout: the JSON `--json` promises is on stdout, and folding a
    # warning line into it would break the parse on the very path that succeeded.
    errors_file="$(mktemp)"
    set +e
    output="$(grantiva simulator ensure --name "$name" --json 2>"$errors_file")"
    status=$?
    set -e
    errors="$(cat "$errors_file")"
    rm -f "$errors_file"
    if (( status != 0 )); then
        if [[ "$output$errors" == *"Multiple simulators are named"* ]]; then
            log "WARNING: grantiva refuses \"$name\" as ambiguous (this machine has more than one simulator of that name); selecting one directly"
            udid="$(duplicate_named_udid "$name")"
            [[ -n "$udid" ]] || { echo "no available simulator named \"$name\"" >&2; exit 1; }
            log "WARNING: using \"$name\" ($udid), booting it without grantiva's ensure"
            xcrun simctl boot "$udid" >/dev/null 2>&1 || true
        else
            printf '%s\n%s\n' "$output" "$errors" >&2
            echo "grantiva simulator ensure --name \"$name\" failed" >&2
            exit 1
        fi
    else
        udid="$(printf '%s' "$output" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("udid", ""))')"
    fi
    [[ -n "$udid" ]] || { echo "grantiva simulator ensure --name \"$name\" returned no UDID" >&2; exit 1; }
    # Belt and braces on top of `ensure`'s own boot: `bootstatus -b` blocks until the device
    # reports itself fully booted, so nothing downstream races a half-started simulator. The
    # elapsed line is what makes a cold CI runner's boot cost visible.
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    log "\"$name\" ready after $((SECONDS - start))s"
    echo "$udid"
}

log "Simulators"
ADVERTISER_UDID="$(ensure_simulator "$ADVERTISER_SIM")"
SCANNER_UDID="$(ensure_simulator "$SCANNER_SIM")"
echo "advertiser: $ADVERTISER_SIM ($ADVERTISER_UDID)"
echo "scanner:    $SCANNER_SIM ($SCANNER_UDID)"

rm -rf "$REPORT_ROOT"
mkdir -p "$ADVERTISER_REPORT" "$SCANNER_REPORT"

# --- Provider ---------------------------------------------------------------
log "Building bleswift-provider"
swift build --product bleswift-provider

log "Starting bleswift-provider on an ephemeral loopback port"
# Port 0: the system picks. The provider line-buffers stdout and names the *bound* port on
# its listening line, so the port is read back from the log rather than assumed.
.build/debug/bleswift-provider --listen "127.0.0.1:0" >"$PROVIDER_LOG" 2>&1 &
PROVIDER_PID=$!

for _ in $(seq 1 30); do
    if grep -q "listening on" "$PROVIDER_LOG" 2>/dev/null; then break; fi
    kill -0 "$PROVIDER_PID" 2>/dev/null || { echo "provider exited early:" >&2; cat "$PROVIDER_LOG" >&2; exit 1; }
    sleep 1
done
grep -q "listening on" "$PROVIDER_LOG" || { echo "provider never reported listening:" >&2; cat "$PROVIDER_LOG" >&2; exit 1; }
cat "$PROVIDER_LOG"

PORT="$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$PROVIDER_LOG" | head -1)"
[[ -n "$PORT" ]] || { echo "could not parse the bound port from the provider log:" >&2; cat "$PROVIDER_LOG" >&2; exit 1; }
LINK_ENDPOINT="127.0.0.1:$PORT"
echo "provider endpoint: $LINK_ENDPOINT"

# --- App --------------------------------------------------------------------
log "Building BLESwiftExplorer for the simulator"
# `generic/platform=iOS Simulator`, not a named device: the build's output is the same
# simulator `.app` either way, and a generic destination needs no device lookup — which on a
# CI runner can fail to enumerate the simulators `simctl` plainly has ("Unable to find a
# device matching the provided destination specifier").
xcodebuild build \
    -project Examples/BLESwiftExplorer/BLESwiftExplorer.xcodeproj \
    -scheme BLESwiftExplorer \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath .build/e2e-dd \
    -skipPackagePluginValidation -skipMacroValidation -quiet

APP="$(find .build/e2e-dd -name BLESwiftExplorer.app -path '*iphonesimulator*' | head -1)"
[[ -n "$APP" ]] || { echo "BLESwiftExplorer.app not found under .build/e2e-dd" >&2; exit 1; }
echo "app: $APP"

# Installed here, before either grantiva session starts. grantiva's own `--app-file` install
# then finds the app already present, and WebDriverAgent comes up against a simulator that has
# already paid for its first install — on a cold CI runner that install is part of what pushes
# WebDriverAgent past its 90-second startup timeout.
for udid in "$ADVERTISER_UDID" "$SCANNER_UDID"; do
    log "Installing $BUNDLE_ID on $udid"
    install_start=$SECONDS
    xcrun simctl install "$udid" "$APP"
    echo "installed in $((SECONDS - install_start))s"
done

# --- Advertiser (keep-alive, background) ------------------------------------
log "Advertiser session on \"$ADVERTISER_SIM\" ($ADVERTISER_UDID)"
# By UDID, not by name: a runner that has two simulators of the same name makes the name
# ambiguous, and grantiva refuses it outright.
grantiva run \
    --simulator "$ADVERTISER_UDID" \
    --app-file "$APP" \
    --bundle-id "$BUNDLE_ID" \
    --flow Scripts/e2e/flows/advertise.yaml \
    --keep-alive \
    --env "BLESWIFT_LINK=$LINK_ENDPOINT" \
    --ready-file "$ADVERTISER_READY_FILE" \
    --report-dir "$ADVERTISER_REPORT" \
    >"$ADVERTISER_LOG" 2>&1 &
ADVERTISER_PID=$!

# `--ready-file` is written once, atomically, after every flow in the session has reached a
# terminal state — so unlike report.json (rewritten as the run progresses) its existence *is*
# the verdict, and the keep-alive session outliving the flows does not confuse the wait.
# Bounded by a wall-clock deadline, not by a count of iterations: each pass also pays for a
# `kill -0`, so counting `sleep 1`s would cut the wait short of the seconds
# `ADVERTISER_READY_TIMEOUT` promises.
ADVERTISER_READY=0
ADVERTISER_WAIT_START=$SECONDS
ADVERTISER_DEADLINE=$((SECONDS + ADVERTISER_READY_TIMEOUT))
NEXT_HEARTBEAT=10
while (( SECONDS < ADVERTISER_DEADLINE )); do
    ELAPSED=$((SECONDS - ADVERTISER_WAIT_START))
    # A heartbeat every ten seconds: without it a cold runner looks hung for minutes while
    # grantiva is quietly building its agent.
    if (( ELAPSED >= NEXT_HEARTBEAT )); then
        echo "waiting for the advertiser flow: ${ELAPSED}s of ${ADVERTISER_READY_TIMEOUT}s"
        NEXT_HEARTBEAT=$((ELAPSED + 10))
    fi
    if [[ -f "$ADVERTISER_READY_FILE" ]]; then
        ADVERTISER_READY=1
        break
    fi
    kill -0 "$ADVERTISER_PID" 2>/dev/null || { echo "advertiser session exited before writing its ready file:" >&2; cat "$ADVERTISER_LOG" >&2; exit 1; }
    sleep 1
done
[[ "$ADVERTISER_READY" == 1 ]] || { echo "advertiser flow did not finish within ${ADVERTISER_READY_TIMEOUT}s:" >&2; cat "$ADVERTISER_LOG" >&2; exit 1; }

ADVERTISER_STATUS="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("status", "unknown"))
except Exception:
    print("unreadable")
' "$ADVERTISER_READY_FILE")"
if [[ "$ADVERTISER_STATUS" != "passed" ]]; then
    echo "advertiser flow reported status \"$ADVERTISER_STATUS\":" >&2
    cat "$ADVERTISER_READY_FILE" >&2
    cat "$ADVERTISER_LOG" >&2
    exit 1
fi
echo "advertiser flow passed; peripheral is live"

# --- Scanner ----------------------------------------------------------------
log "Scanner session on \"$SCANNER_SIM\" ($SCANNER_UDID)"
set +e
grantiva run \
    --simulator "$SCANNER_UDID" \
    --app-file "$APP" \
    --bundle-id "$BUNDLE_ID" \
    --flow Scripts/e2e/flows/scan-finds-advertiser.yaml \
    --env "BLESWIFT_LINK=$LINK_ENDPOINT" \
    --report-dir "$SCANNER_REPORT"
SCANNER_STATUS=$?
set -e

log "Scanner exited with $SCANNER_STATUS"
exit "$SCANNER_STATUS"

#!/usr/bin/env bash
#
# Two-simulator BLE end-to-end test.
#
# One simulator advertises as "BLESwift Explorer Sim" (service 180D). A second simulator scans and
# must find it. The simulators do not have Bluetooth, so each Explorer app sends its Central and
# PeripheralHost calls to `bleswift-provider` on the Mac. The provider runs without `--passthrough`,
# so the two apps connect through its virtual radio. The test needs no hardware and no entitlements.
#
# The provider binds an ephemeral port (`--listen 127.0.0.1:0`). The script reads the bound port
# from the provider's listening line and gives it to both apps as `--env
# BLESWIFT_LINK=127.0.0.1:<port>`. `SimulatorLink.install()` resolves this value through
# `LinkEndpoint.fromEnvironment()`. The script does not pin a port, so a port already in use on the
# machine cannot collide with this run.
#
# Usage: Scripts/sim-to-sim-e2e.sh
#
# Environment variables:
#   ADVERTISER_SIM            Name of the simulator for the peripheral.
#                             Default: "iPhone 17 Pro"
#   SCANNER_SIM               Name of the simulator for the central.
#                             Default: "iPhone 17"
#   ADVERTISER_READY_TIMEOUT  Seconds to wait for the advertiser flow to pass.
#                             Default: 900
#
# See Scripts/e2e/README.md.

set -euo pipefail

ADVERTISER_SIM="${ADVERTISER_SIM:-iPhone 17 Pro}"
SCANNER_SIM="${SCANNER_SIM:-iPhone 17}"
# The default is long. On a cold runner, grantiva builds its agent (5-10 minutes in its own log) and
# a WebDriverAgent runner before the first step of the flow runs, and this time counts inside this
# wait. The 25-minute limit of the CI job is the real upper limit.
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

# Write to stderr, so that a `log` call inside a function with captured stdout (see
# `ensure_simulator`) cannot attach to the value that the function returns.
log() { printf '\n==> %s\n' "$*" >&2; }

cleanup() {
    local status=$?
    log "Tearing down"
    if [[ -n "$ADVERTISER_PID" ]] && kill -0 "$ADVERTISER_PID" 2>/dev/null; then
        # The keep-alive session holds the runner open. SIGINT is the documented way to release it
        # ("Release with Ctrl-C").
        kill -INT "$ADVERTISER_PID" 2>/dev/null || true
        sleep 3
        kill -9 "$ADVERTISER_PID" 2>/dev/null || true
    fi
    # A kill of `grantiva run` can leave these child processes running, and they keep the simulator
    # "owned by another Grantiva run":
    #   - the `grantiva-runner` child
    #   - the WebDriverAgent `xcodebuild test-without-building`
    #   - a `simctl diagnose` log collection
    # `teardown --udid --force` reclaims one device by inspection of live processes. It kills
    # exactly these three processes, breaks the lease, and reconciles the session registry.
    for udid in "$ADVERTISER_UDID" "$SCANNER_UDID"; do
        [[ -n "$udid" ]] || continue
        grantiva simulator teardown --udid "$udid" --force >/dev/null 2>&1 || true
        xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    if [[ -n "$PROVIDER_PID" ]] && kill -0 "$PROVIDER_PID" 2>/dev/null; then
        # Send TERM first, so that the provider's handler runs `stop()` and closes its sessions.
        # Send SIGKILL only if the provider is still running three seconds later.
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
# `grantiva simulator ensure --name <name>` finds or creates a simulator. It reuses a simulator with
# that name if one exists. Otherwise it creates the simulator on the newest installed iOS runtime.
# grantiva 2.0 does not infer a device type from a name without a model in it ("BLESwift CI
# Advertiser" has no model, on purpose; see the workflow), so the script resolves the newest
# numbered iPhone type once for the create path. By default, `ensure` boots the simulator and
# reports the UDID. Every later command takes the UDID.
#
# `--device-type` is not only for creation. `ensure` checks an existing device against it and
# against the newest runtime (the default), and refuses a mismatch ("exists with incompatible
# configuration"). So for an existing device, the script uses that device's type and runtime
# (`existing_configuration`). A step before this script decides which device CI uses:
# `Scripts/ci/ensure-ci-simulator.sh` creates and refreshes the CI device, and a manual dispatch
# names the user's device. Do not check this decision again in this script.
#
# Use `--json`, not the plain output. The plain output of `ensure` is a sentence for people, for
# example "Reused iPhone 17 Pro (<UDID>) — Booted", which the script would have to parse.
#
# `ensure` refuses one case completely: a machine with two simulators of the same name. It answers
# with `Multiple simulators are named "<name>"; delete duplicates or use a unique name`. The GitHub
# runner image has three "iPhone 17 Pro Max" devices, so this case is real. This script must not
# delete a runner's devices. Instead, it resolves the duplicate in these steps:
#   1. Select one device of that name from `simctl list devices available`.
#   2. Prefer a device that is already booted.
#   3. Continue with the UDID, which every later command takes.
# The script always shows a warning for this case.
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

# "<device type identifier> <runtime identifier>" of an available device of that name, a booted
# device first, as above. The function prints nothing if no device exists, and then `ensure` creates
# the device.
existing_configuration() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
matches = [(runtime, d) for runtime in devices for d in devices[runtime] if d["name"] == name]
matches.sort(key=lambda m: m[1].get("state") != "Booted")
if matches:
    print(matches[0][1]["deviceTypeIdentifier"], matches[0][0])
' "$1"
}

ci_device_type="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
types = [t for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone")]
if not types:
    sys.exit("no iPhone device type is installed")
def rank(t):
    parts = t["name"].split()
    return (1, int(parts[1]), t["name"]) if len(parts) > 1 and parts[1].isdigit() else (0, 0, t["name"])
print(sorted(types, key=rank)[-1]["identifier"])
')"

ensure_simulator() {
    local name="$1"
    local start=$SECONDS
    local udid output errors status errors_file
    # Keep stderr separate from stdout. The JSON that `--json` gives is on stdout, and a warning
    # line in it would break the parse on a path that succeeded.
    local existing_type existing_runtime
    local configuration=(--device-type "$ci_device_type")
    read -r existing_type existing_runtime <<<"$(existing_configuration "$name")" || true
    if [[ -n "$existing_type" ]]; then
        configuration=(--device-type "$existing_type" --runtime "$existing_runtime")
    fi
    errors_file="$(mktemp)"
    set +e
    output="$(grantiva simulator ensure --name "$name" "${configuration[@]}" --json 2>"$errors_file")"
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
    # Extra safety on top of the boot that `ensure` does. `bootstatus -b` blocks until the device
    # reports a full boot, so no later command runs against a half-started simulator. The
    # elapsed-time line shows how long a cold CI runner needs to boot.
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
# Port 0: the system selects the port. The provider line-buffers stdout and names the *bound* port
# on its listening line, so the script reads the port from the log and does not assume it.
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
# Build for `generic/platform=iOS Simulator`, not for a named device. The build output is the same
# simulator `.app`, and a generic destination needs no device lookup. On a CI runner, the lookup can
# fail to list the simulators that `simctl` shows ("Unable to find a device matching the provided
# destination specifier").
xcodebuild build \
    -project Examples/BLESwiftExplorer/BLESwiftExplorer.xcodeproj \
    -scheme BLESwiftExplorer \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath .build/e2e-dd \
    -skipPackagePluginValidation -skipMacroValidation -quiet

APP="$(find .build/e2e-dd -name BLESwiftExplorer.app -path '*iphonesimulator*' | head -1)"
[[ -n "$APP" ]] || { echo "BLESwiftExplorer.app not found under .build/e2e-dd" >&2; exit 1; }
echo "app: $APP"

# The script installs the app here, before either grantiva session starts, so grantiva's
# `--app-file` install finds the app already present. WebDriverAgent then starts against a simulator
# that already paid for its first install. On a cold CI runner, this install is one reason that
# WebDriverAgent can pass its startup timeout of 90 seconds.
for udid in "$ADVERTISER_UDID" "$SCANNER_UDID"; do
    log "Installing $BUNDLE_ID on $udid"
    install_start=$SECONDS
    xcrun simctl install "$udid" "$APP"
    echo "installed in $((SECONDS - install_start))s"
done

# --- Advertiser (keep-alive, background) ------------------------------------
log "Advertiser session on \"$ADVERTISER_SIM\" ($ADVERTISER_UDID)"
# Select the simulator by UDID, not by name. If a runner has two simulators of the same name, the
# name is ambiguous, and grantiva refuses an ambiguous name completely.
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

# grantiva writes `--ready-file` once, atomically, after every flow in the session reached a final
# state. report.json changes while the run progresses, but the existence of the ready file is the
# result, so it does not matter that the keep-alive session continues after the flows. A wall-clock
# deadline limits the wait, not a count of iterations: each pass also spends time on `kill -0`, so a
# count of `sleep 1` calls would stop the wait before the seconds that `ADVERTISER_READY_TIMEOUT`
# promises.
ADVERTISER_READY=0
ADVERTISER_WAIT_START=$SECONDS
ADVERTISER_DEADLINE=$((SECONDS + ADVERTISER_READY_TIMEOUT))
NEXT_HEARTBEAT=10
while (( SECONDS < ADVERTISER_DEADLINE )); do
    ELAPSED=$((SECONDS - ADVERTISER_WAIT_START))
    # Print a heartbeat every ten seconds. Without it, a cold runner looks frozen for minutes while
    # grantiva builds its agent silently.
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

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
# The port is fixed at 45541, `LinkEndpoint.default`. Nothing can set
# `BLESWIFT_LINK` on an app driven by the UI runner, so both simulators dial the
# default and a provider listening anywhere else would simply never be found.
#
# See Scripts/e2e/README.md.

set -euo pipefail

ADVERTISER_SIM="${ADVERTISER_SIM:-iPhone 17 Pro}"
SCANNER_SIM="${SCANNER_SIM:-iPhone 17}"
# `LinkEndpoint.default`, and not overridable — see the header.
readonly PORT=45541
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
    # `grantiva run` does NOT take its children down with it: killing it strands a
    # `grantiva-runner` and the WebDriverAgent `xcodebuild test-without-building`,
    # and the stranded pair keeps the simulator "owned by another Grantiva run".
    # Reap them explicitly, scoped to the simulators this script drove.
    grantiva runner stop >/dev/null 2>&1 || true
    for udid in "$ADVERTISER_UDID" "$SCANNER_UDID"; do
        [[ -n "$udid" ]] || continue
        pkill -f "grantiva-runner .*--device $udid" >/dev/null 2>&1 || true
        pkill -f "test-without-building .*-destination id=$udid" >/dev/null 2>&1 || true
        pkill -f "simctl diagnose .*--udid=$udid" >/dev/null 2>&1 || true
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
# Idempotent: look the simulator up by name, create + boot it if it is missing.
ensure_simulator() {
    local name="$1"
    local udid
    udid="$(xcrun simctl list devices available -j \
        | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)["devices"]
for runtime, devices in data.items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device["name"] == name:
            print(device["udid"])
            sys.exit(0)
' "$name")"
    if [[ -z "$udid" ]]; then
        log "Creating simulator \"$name\""
        local runtime
        runtime="$(xcrun simctl list runtimes -j \
            | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r["isAvailable"] and r["platform"] == "iOS"]
print(runtimes[-1]["identifier"] if runtimes else "")
')"
        [[ -n "$runtime" ]] || { echo "no available iOS runtime" >&2; exit 1; }
        udid="$(xcrun simctl create "$name" "$name" "$runtime")"
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
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

log "Starting bleswift-provider on 127.0.0.1:$PORT"
.build/debug/bleswift-provider --listen "127.0.0.1:$PORT" >"$PROVIDER_LOG" 2>&1 &
PROVIDER_PID=$!

for _ in $(seq 1 30); do
    if grep -q "listening on" "$PROVIDER_LOG" 2>/dev/null; then break; fi
    kill -0 "$PROVIDER_PID" 2>/dev/null || { echo "provider exited early:" >&2; cat "$PROVIDER_LOG" >&2; exit 1; }
    sleep 1
done
grep -q "listening on" "$PROVIDER_LOG" || { echo "provider never reported listening:" >&2; cat "$PROVIDER_LOG" >&2; exit 1; }
cat "$PROVIDER_LOG"

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

# --- Advertiser (keep-alive, background) ------------------------------------
log "Advertiser session on \"$ADVERTISER_SIM\""
grantiva run \
    --simulator "$ADVERTISER_SIM" \
    --app-file "$APP" \
    --bundle-id "$BUNDLE_ID" \
    --flow Scripts/e2e/flows/advertise.yaml \
    --keep-alive \
    --report-dir "$ADVERTISER_REPORT" \
    >"$ADVERTISER_LOG" 2>&1 &
ADVERTISER_PID=$!

# grantiva exposes no readiness signal for a keep-alive session, so poll the
# report it writes when the flow finishes.
# Bounded by a wall-clock deadline, not by a count of iterations: each pass also
# pays for a `grep`, a `python3` and a `kill -0`, so counting `sleep 1`s would cut
# the wait well short of the seconds `ADVERTISER_READY_TIMEOUT` promises.
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
    if [[ -f "$ADVERTISER_REPORT/report.json" ]]; then
        # report.json is rewritten as the run progresses (see its `updateSeq`),
        # so a file on disk is not yet a verdict: keep polling while the status
        # is still running/pending, and bail out on anything but "passed".
        STATUS="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("status", "pending"))
except Exception:
    print("pending")
' "$ADVERTISER_REPORT/report.json")"
        case "$STATUS" in
            passed)
                ADVERTISER_READY=1
                break
                ;;
            running|pending)
                ;;
            *)
                echo "advertiser flow reported status \"$STATUS\":" >&2
                cat "$ADVERTISER_REPORT/report.json" >&2
                cat "$ADVERTISER_LOG" >&2
                exit 1
                ;;
        esac
    fi
    kill -0 "$ADVERTISER_PID" 2>/dev/null || { echo "advertiser session exited before writing a report:" >&2; cat "$ADVERTISER_LOG" >&2; exit 1; }
    sleep 1
done
[[ "$ADVERTISER_READY" == 1 ]] || { echo "advertiser flow did not pass within ${ADVERTISER_READY_TIMEOUT}s:" >&2; cat "$ADVERTISER_LOG" >&2; exit 1; }
echo "advertiser flow passed; peripheral is live"

# --- Scanner ----------------------------------------------------------------
log "Scanner session on \"$SCANNER_SIM\""
set +e
grantiva run \
    --simulator "$SCANNER_SIM" \
    --app-file "$APP" \
    --bundle-id "$BUNDLE_ID" \
    --flow Scripts/e2e/flows/scan-finds-advertiser.yaml \
    --report-dir "$SCANNER_REPORT"
SCANNER_STATUS=$?
set -e

log "Scanner exited with $SCANNER_STATUS"
exit "$SCANNER_STATUS"

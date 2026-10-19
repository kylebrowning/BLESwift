#!/bin/zsh
# Prints the UDID of a simulator dedicated to CI, creating it if it does not exist.
#
#   Scripts/ci/ensure-ci-simulator.sh <name> [<ios-major>]
#
# The optional second argument pins an iOS major (e.g. "17"): the runtime is then the
# highest installed one of that major, and no such runtime is an error naming the
# `xcodebuild -downloadPlatform` command that installs it, not a fall back to a newer one.
# Without it the runtime is the highest installed of any major.
#
# CI on a self-hosted runner shares the machine with whoever sits at it. A job that picks
# "the newest iPhone" by name picks the device that person is debugging on, installs a test
# app into it and — in the E2E — force-tears it down afterwards. So CI devices carry names
# nobody else uses, and every job resolves them here.
#
# A device of that name is reused (booted or not; the caller boots it) when it is available
# and on the chosen runtime; one on another runtime, or left unavailable because its runtime
# was removed, is deleted and recreated, so the CI device follows runtime installs rather
# than freezing on the one it was created with. A delete that fails is fatal: `grantiva
# simulator ensure --name` refuses a duplicated name, and creating alongside a stale device
# would hand the E2E that ambiguity on every run. Creation uses the newest numbered iPhone
# the chosen runtime itself supports — an older runtime does not support every device type
# the host has installed — on that runtime (several builds of one version share an
# identifier; which build is CoreSimulator's).
set -euo pipefail
name="$1"
major="${2:-}"   # optional iOS major, e.g. "17"; empty means the highest installed

# Each Python block prints its own diagnostic and exits non-zero itself: under `set -e` a
# failing command substitution aborts the assignment, so a shell guard after it never runs.
runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
major = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
if major:
    runtimes = [r for r in runtimes if r["version"].split(".")[0] == major]
    if not runtimes:
        sys.exit(f"no iOS {major} runtime is installed; install one with: xcodebuild -downloadPlatform iOS -buildVersion {major}.5")
if not runtimes:
    sys.exit("no iOS runtime is installed")
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(runtimes[-1]["identifier"])
' "$major")"

# One line per existing device of that name: "keep <udid>" for an available device on the
# chosen runtime, "replace <udid>" for anything else (another runtime, or unavailable).
plan="$(mktemp)"
trap 'rm -f "$plan"' EXIT
xcrun simctl list devices -j | python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"]
for rt in devices:
    for d in devices[rt]:
        if d["name"] != name:
            continue
        current = d.get("isAvailable", True) and rt == runtime
        print(("keep " if current else "replace ") + d["udid"])
' "$name" "$runtime" >"$plan"

existing=""
while read -r action udid; do
    case "$action" in
        keep)
            # Exactly one device of the name survives: a second current one (hand-created, or a
            # second runner service) is deleted too, or the E2E's `ensure --name` sees a duplicate.
            if [[ -n "$existing" ]]; then
                echo "deleting \"$name\" ($udid): duplicate of $existing" >&2
                xcrun simctl delete "$udid" >&2 || { echo "could not delete duplicate \"$name\" ($udid)" >&2; exit 1; }
            else
                existing="$udid"
            fi
            ;;
        replace)
            echo "deleting \"$name\" ($udid): unavailable or not on $runtime" >&2
            xcrun simctl delete "$udid" >&2 || { echo "could not delete \"$name\" ($udid); refusing to create a duplicate" >&2; exit 1; }
            ;;
    esac
done <"$plan"
if [[ -n "$existing" ]]; then
    print -- "$existing"
    exit 0
fi

device_type="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtime = sys.argv[1]
rts = [r for r in json.load(sys.stdin)["runtimes"] if r["identifier"] == runtime]
types = [t for t in rts[0]["supportedDeviceTypes"] if t["name"].startswith("iPhone")] if rts else []
if not types:
    sys.exit(f"{runtime} supports no iPhone device type")
def rank(t):
    parts = t["name"].split()
    return (1, int(parts[1]), t["name"]) if len(parts) > 1 and parts[1].isdigit() else (0, 0, t["name"])
print(sorted(types, key=rank)[-1]["identifier"])
' "$runtime")"

# `simctl create` prints the new UDID; anything else on stdout (beta Xcodes chatter on some
# paths) must not reach the caller, which writes this into GITHUB_ENV one line at a time.
# `|| true` so a no-match grep reaches the guard below instead of aborting under `set -e`.
created="$(xcrun simctl create "$name" "$device_type" "$runtime")"
udid="$(print -- "$created" | grep -E -o -m1 '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)"
[[ -n "$udid" ]] || { echo "simctl create did not return a UDID:" >&2; print -- "$created" >&2; exit 1; }
print -- "$udid"

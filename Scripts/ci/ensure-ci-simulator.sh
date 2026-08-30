#!/bin/zsh
# Prints the UDID of a simulator dedicated to CI, creating it if it does not exist.
#
#   Scripts/ci/ensure-ci-simulator.sh "BLESwift CI Test"
#
# CI on a self-hosted runner shares the machine with whoever sits at it. A job that picks
# "the newest iPhone" by name picks the device that person is debugging on, installs a test
# app into it and — in the E2E — force-tears it down afterwards. So CI devices carry names
# nobody else uses, and every job resolves them here.
#
# A device of that name is reused (booted or not; the caller boots it) when it is available
# and on the highest-version iOS runtime installed; one on an older runtime, or left
# unavailable because its runtime was removed, is deleted and recreated, so the CI device
# follows runtime installs rather than freezing on the one it was created with. A delete
# that fails is fatal: `grantiva simulator ensure --name` refuses a duplicated name, and
# creating alongside a stale device would hand the E2E that ambiguity on every run. Creation
# uses the newest numbered iPhone device type and an installed iOS runtime of the highest
# version (several builds of one version share an identifier; which build is CoreSimulator's).
set -euo pipefail
name="$1"

# Each Python block prints its own diagnostic and exits non-zero itself: under `set -e` a
# failing command substitution aborts the assignment, so a shell guard after it never runs.
runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
if not runtimes:
    sys.exit("no iOS runtime is installed")
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(runtimes[-1]["identifier"])
')"

# One line per existing device of that name: "keep <udid>" for an available device on the
# newest runtime, "replace <udid>" for anything else (older runtime, or unavailable).
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
            [[ -n "$existing" ]] || existing="$udid"
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

device_type="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
types = [t for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone")]
if not types:
    sys.exit("no iPhone device type is installed")
def rank(t):
    parts = t["name"].split()
    return (1, int(parts[1]), t["name"]) if len(parts) > 1 and parts[1].isdigit() else (0, 0, t["name"])
print(sorted(types, key=rank)[-1]["identifier"])
')"

# `simctl create` prints the new UDID; anything else on stdout (beta Xcodes chatter on some
# paths) must not reach the caller, which writes this into GITHUB_ENV one line at a time.
# `|| true` so a no-match grep reaches the guard below instead of aborting under `set -e`.
created="$(xcrun simctl create "$name" "$device_type" "$runtime")"
udid="$(print -- "$created" | grep -E -o -m1 '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)"
[[ -n "$udid" ]] || { echo "simctl create did not return a UDID:" >&2; print -- "$created" >&2; exit 1; }
print -- "$udid"

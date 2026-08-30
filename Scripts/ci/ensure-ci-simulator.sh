#!/bin/zsh
# Prints the UDID of a simulator dedicated to CI, creating it if it does not exist.
#
#   Scripts/ci/ensure-ci-simulator.sh "BLESwift CI Test"
#
# CI on a self-hosted runner shares the machine with whoever sits at it. A job that picks
# "the newest iPhone" by name picks the device that person is debugging on, installs a test
# app into it and — in the E2E — force-tears it down afterwards. So CI devices carry names
# nobody else uses, and every job resolves them here: an available device of that name is
# reused (booted or not; the caller boots it). A same-named device whose runtime has been
# removed — each Xcode beta replaces the iOS runtime build — is deleted first, because
# `grantiva simulator ensure --name` refuses a duplicated name and the E2E would fall into
# its ambiguity fallback on every run thereafter. Otherwise one is created from the newest
# numbered iPhone device type and an installed iOS runtime of the highest version (several
# builds of one version share an identifier, so which build is CoreSimulator's choice).
set -euo pipefail
name="$1"

existing="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
matches = [d for runtime in devices for d in devices[runtime] if d["name"] == name]
available = [d for d in matches if d.get("isAvailable", True)]
stale = [d for d in matches if not d.get("isAvailable", True)]
print(available[0]["udid"] if available else "")
for d in stale:
    print("stale " + d["udid"], file=sys.stderr)
' "$name" 2>"${TMPDIR:-/tmp}/ensure-ci-simulator.$$")"
while read -r word udid; do
    [[ "$word" == "stale" ]] || continue
    echo "deleting unavailable \"$name\" ($udid)" >&2
    xcrun simctl delete "$udid" >&2 || true
done <"${TMPDIR:-/tmp}/ensure-ci-simulator.$$"
rm -f "${TMPDIR:-/tmp}/ensure-ci-simulator.$$"
if [[ -n "$existing" ]]; then
    print -- "$existing"
    exit 0
fi

# The Python prints the intended message and exits non-zero itself: under `set -e` a failing
# command substitution aborts the assignment, so a shell-side guard after it would never run.
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
runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
if not runtimes:
    sys.exit("no iOS runtime is installed")
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(runtimes[-1]["identifier"])
')"

# `simctl create` prints the new UDID; anything else on stdout (beta Xcodes chatter on some
# paths) must not reach the caller, which writes this into GITHUB_ENV one line at a time.
created="$(xcrun simctl create "$name" "$device_type" "$runtime")"
udid="$(print -- "$created" | grep -E -o '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)"
[[ -n "$udid" ]] || { echo "simctl create did not return a UDID:" >&2; print -- "$created" >&2; exit 1; }
print -- "$udid"

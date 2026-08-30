#!/bin/zsh
# Prints the UDID of a simulator dedicated to CI, creating it if it does not exist.
#
#   Scripts/ci/ensure-ci-simulator.sh "BLESwift CI Test"
#
# CI on a self-hosted runner shares the machine with whoever sits at it. A job that picks
# "the newest iPhone" by name picks the device that person is debugging on, installs a test
# app into it and — in the E2E — force-tears it down afterwards. So CI devices carry names
# nobody else uses, and every job resolves them here: an existing device of that name is
# reused (booted or not; the caller boots it), otherwise one is created from the newest
# numbered iPhone device type and the newest available iOS runtime on the machine.
set -euo pipefail
name="$1"
existing="$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
matches = [d for runtime in devices for d in devices[runtime]
           if d["name"] == name and d.get("isAvailable", True)]
print(matches[0]["udid"] if matches else "")
' "$name")"
if [[ -n "$existing" ]]; then
    print -- "$existing"
    exit 0
fi
device_type="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
types = [t for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone")]
def rank(t):
    parts = t["name"].split()
    return (1, int(parts[1]), t["name"]) if len(parts) > 1 and parts[1].isdigit() else (0, 0, t["name"])
print(sorted(types, key=rank)[-1]["identifier"])
')"
runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
runtimes.sort(key=lambda r: ([int(x) for x in r["version"].split(".")], r["buildversion"]))
print(runtimes[-1]["identifier"])
')"
[[ -n "$device_type" && -n "$runtime" ]] || { echo "no iPhone device type or iOS runtime installed" >&2; exit 1; }
xcrun simctl create "$name" "$device_type" "$runtime"

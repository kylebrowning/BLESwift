#!/bin/zsh
# Prints the UDID of a simulator dedicated to CI. The script creates the simulator if it does not
# exist.
#
#   Scripts/ci/ensure-ci-simulator.sh <name> [<ios-major>]
#
# The optional second argument pins an iOS major version (for example "17"). The runtime is then the
# highest installed runtime of that major version. If none exists, the script stops with an error
# that tells how to install one, and does not use a newer runtime. Without the second argument, the
# runtime is the highest installed runtime of any major version.
#
# CI on a self-hosted runner shares the machine with the person who sits at it. A job that selects
# "the newest iPhone" by name selects the device that this person debugs on. The job installs a test
# app into that device and, in the E2E, force-tears it down afterward. So CI devices have names that
# nobody else uses, and every job resolves them here.
#
# The script reuses a device of that name if it is available and on the chosen runtime. The device
# can be booted or not. The caller boots it. The script deletes and recreates a device in these
# cases:
#   - The device is on another runtime.
#   - The device is unavailable because its runtime was removed.
# So the CI device follows runtime installs and does not stay on the runtime of its creation.
#
# If a delete fails, the script stops with an error, because `grantiva simulator ensure --name`
# refuses a duplicated name. A device created next to a stale device would make the E2E see this
# problem on every run.
#
# The script creates the device on the chosen runtime, with the newest numbered iPhone that this
# runtime supports. An older runtime does not support every device type that the host has installed.
# Several builds of one version share an identifier, and CoreSimulator decides which build is used.
set -euo pipefail
name="$1"
major="${2:-}"   # optional iOS major, for example "17". If empty, use the highest installed major.

# Each Python block prints its own diagnostic and exits with a non-zero status itself. Under `set
# -e`, a failing command substitution aborts the assignment, so a shell guard after it never runs.
runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
major = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
if major:
    runtimes = [r for r in runtimes if r["version"].split(".")[0] == major]
    if not runtimes:
        sys.exit(
            f"no iOS {major} runtime is installed; install an iOS {major}.x runtime, e.g. "
            f"`xcodebuild -downloadPlatform iOS -buildVersion {major}.5`. An Xcode newer than "
            f"that runtime may refuse to download it; then download its .dmg from "
            f"developer.apple.com and run `xcodebuild -importPlatform <dmg>`"
        )
if not runtimes:
    sys.exit("no iOS runtime is installed")
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(runtimes[-1]["identifier"])
' "$major")"

# One line for each existing device of that name.
# "keep <udid>" is for an available device on the chosen runtime.
# "replace <udid>" is for any other device (on another runtime, or unavailable).
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
            # Exactly one device of the name survives. The script also deletes a second current
            # device (created by hand, or by a second runner service). Otherwise the E2E's `ensure
            # --name` sees a duplicate.
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
if not rts:
    sys.exit(f"{runtime} is no longer installed; it was removed after this script chose it")
types = [t for t in rts[0].get("supportedDeviceTypes", []) if t["name"].startswith("iPhone")]
if not types:
    sys.exit(f"{runtime} supports no iPhone device type")
def rank(t):
    parts = t["name"].split()
    return (1, int(parts[1]), t["name"]) if len(parts) > 1 and parts[1].isdigit() else (0, 0, t["name"])
print(sorted(types, key=rank)[-1]["identifier"])
' "$runtime")"

# `simctl create` prints the new UDID. Other output on stdout (beta Xcodes can print extra text on
# some paths) must not reach the caller, which writes this output into GITHUB_ENV one line at a
# time. The `|| true` lets a grep without a match reach the guard below. Without it, the script
# would abort under `set -e`.
created="$(xcrun simctl create "$name" "$device_type" "$runtime")"
udid="$(print -- "$created" | grep -E -o -m1 '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)"
[[ -n "$udid" ]] || { echo "simctl create did not return a UDID:" >&2; print -- "$created" >&2; exit 1; }
print -- "$udid"

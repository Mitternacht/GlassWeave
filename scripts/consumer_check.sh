#!/bin/sh
# Clean-consumer check (GW-10).
#
# Copies Examples/ConsumerCheck into a fresh temporary directory, makes it
# depend on this clone of GlassWeave by a file:// git URL at one revision,
# checks that SwiftPM pins exactly that revision and nothing else, and runs
# the consumer's public-API tests with Metal API Validation on.
#
# Usage: scripts/consumer_check.sh [revision] [xcodebuild destination]...
#   revision     a committed revision (default HEAD); uncommitted changes are
#                not part of the check
#   destination  default 'platform=macOS'; pass more, for example
#                'platform=iOS Simulator,name=<simulator>'
set -eu

root="$(git rev-parse --show-toplevel)"
revision="$(git -C "$root" rev-parse --verify "${1:-HEAD}^{commit}")"
[ "$#" -gt 0 ] && shift
[ "$#" -eq 0 ] && set -- 'platform=macOS'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$root/Examples/ConsumerCheck" "$work/ConsumerCheck"
cd "$work/ConsumerCheck"

export GLASSWEAVE_URL="file://$root"
export GLASSWEAVE_REVISION="$revision"
# Forwarded to the test process by xcodebuild (TEST_RUNNER_ prefix).
export TEST_RUNNER_MTL_DEBUG_LAYER=1

echo "Consumer check of GlassWeave at $revision"
xcodebuild -resolvePackageDependencies -scheme GlassWeaveConsumer -derivedDataPath "$work/DerivedData" >"$work/resolve.log" 2>&1 || {
    cat "$work/resolve.log"
    exit 1
}

python3 - "$revision" "$(basename "$root" | tr '[:upper:]' '[:lower:]')" <<'PY'
import json, sys
revision, identity = sys.argv[1], sys.argv[2]
pins = json.load(open("Package.resolved"))["pins"]
summary = [(p["identity"], p["kind"], p["state"].get("revision")) for p in pins]
print("Resolved pins:", summary)
if len(pins) != 1 or pins[0]["identity"] != identity or pins[0]["state"].get("revision") != revision:
    sys.exit(f"Expected exactly one pin, {identity} at {revision}")
PY

for destination in "$@"; do
    echo "Testing on $destination"
    xcodebuild test -scheme GlassWeaveConsumer -destination "$destination" \
        -derivedDataPath "$work/DerivedData" CODE_SIGNING_ALLOWED=NO >"$work/test.log" 2>&1 || {
        tail -n 80 "$work/test.log"
        exit 1
    }
    grep -E "Test run with|passed after|failed after|TEST SUCCEEDED|TEST FAILED" "$work/test.log" || true
done

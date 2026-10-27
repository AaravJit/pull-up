#!/usr/bin/env bash
# resolve-packages.sh <derived-data-path>: resolves Swift packages for the
# Store media builds (Xcode 27.1). Tries the committed versions first
# (pin-packages.sh, no automatic resolution). If Xcode 27.1 refuses that
# file, prints why, lets Xcode resolve, and prints any version difference
# from native/ios/Package.resolved so the captured build's packages are on
# record. Run from native/ios after xcodegen generate && pin-packages.sh.
set -uo pipefail
DD=$1
LOG="${RUNNER_TEMP:-/tmp}/resolve-packages.log"
args=(-resolvePackageDependencies -project PullUp.xcodeproj -scheme PullUp -derivedDataPath "$DD" -skipPackagePluginValidation)
if xcodebuild "${args[@]}" -disableAutomaticPackageResolution > "$LOG" 2>&1; then
  echo "Packages resolved from the committed Package.resolved"
  tail -n 15 "$LOG"
  exit 0
fi
echo "::warning::Xcode couldn't build from the committed Package.resolved without resolving; its reason:"
grep -v "^\s*$" "$LOG" | tail -n 40
if ! xcodebuild "${args[@]}" > "$LOG.2" 2>&1; then
  tail -n 60 "$LOG.2"
  echo "::error::Package resolution failed"
  exit 1
fi
tail -n 20 "$LOG.2"
resolved=PullUp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
python3 - Package.resolved "$resolved" <<'PY'
import json, sys
def pins(path):
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        return {}
    return {p["identity"]: p["state"].get("version") or p["state"].get("revision") for p in data.get("pins", [])}
committed, used = pins(sys.argv[1]), pins(sys.argv[2])
for name in sorted(set(committed) | set(used)):
    mark = "" if committed.get(name) == used.get(name) else "   <-- differs"
    print("%-28s committed %-12s used %-12s%s" % (name, committed.get(name), used.get(name), mark))
PY

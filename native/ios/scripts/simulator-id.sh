#!/usr/bin/env bash
# Prints the UDID of the iPhone simulator CI should use: the preferred model
# on the newest installed iOS runtime, falling back to any iPhone. Keeps CI
# working as GitHub rotates Xcode and simulator images.
set -euo pipefail
PREFERRED="${PREFERRED_SIMULATOR:-iPhone 17 Pro}"
xcrun simctl list devices available -j | PREFERRED="$PREFERRED" python3 -c '
import json, os, sys
preferred = os.environ["PREFERRED"]
devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, devs in devices.items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.split("iOS-")[1].split("-") if x.isdigit())
    for dev in devs:
        if dev["name"].startswith("iPhone"):
            candidates.append((version, dev["name"] == preferred, "Pro" in dev["name"], dev["udid"], dev["name"]))
if not candidates:
    sys.exit("No iPhone simulator available")
candidates.sort()
best = candidates[-1]
print(best[3])
version = ".".join(map(str, best[0]))
print("Using %s (iOS %s)" % (best[4], version), file=sys.stderr)
'

#!/usr/bin/env bash
# Prints the UDID of the iPhone simulator CI should use: the preferred model
# on the newest installed iOS runtime, falling back to any iPhone. Keeps CI
# working as GitHub rotates Xcode and simulator images.
# IOS_BELOW=26.5 restricts the choice to runtimes older than that version.
set -euo pipefail
PREFERRED="${PREFERRED_SIMULATOR:-iPhone 17 Pro}"
xcrun simctl list devices available -j | PREFERRED="$PREFERRED" IOS_BELOW="${IOS_BELOW:-}" python3 -c '
import json, os, sys
preferred = os.environ["PREFERRED"]
below = tuple(int(x) for x in os.environ["IOS_BELOW"].split(".")) if os.environ["IOS_BELOW"] else None
devices = json.load(sys.stdin)["devices"]
candidates = []
runtimes = set()
for runtime, devs in devices.items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.split("iOS-")[1].split("-") if x.isdigit())
    runtimes.add(version)
    if below and version >= below:
        continue
    for dev in devs:
        if dev["name"].startswith("iPhone"):
            candidates.append((version, dev["name"] == preferred, "Pro" in dev["name"], dev["udid"], dev["name"]))
print("iOS runtimes: " + ", ".join(".".join(map(str, v)) for v in sorted(runtimes)), file=sys.stderr)
if not candidates:
    sys.exit("No iPhone simulator available" + (" below iOS %s" % os.environ["IOS_BELOW"] if below else ""))
candidates.sort()
best = candidates[-1]
print(best[3])
version = ".".join(map(str, best[0]))
print("Using %s (iOS %s)" % (best[4], version), file=sys.stderr)
'

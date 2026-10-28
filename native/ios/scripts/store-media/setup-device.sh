#!/usr/bin/env bash
# setup-device.sh <name> <app-path> <device-type-id> [<device-type-id> ...]
# Creates and boots a fresh simulator for Store media, with the first device
# type (in the order given) that one of $RUNTIMES (newest first) can run.
# Gives it a fixed status bar, dark appearance, a simulated location near
# the demo data and location access already granted (so no permission alert
# covers a capture), installs the app and prints the simulator's UDID.
set -euo pipefail
NAME=$1
APP=$2
shift 2
RUNTIMES=${RUNTIMES:-"com.apple.CoreSimulator.SimRuntime.iOS-27-1 com.apple.CoreSimulator.SimRuntime.iOS-27-0"}
UDID=""
for TYPE in "$@"; do
  for RUNTIME in $RUNTIMES; do
    if UDID=$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME" 2>/dev/null); then
      echo "Created $NAME: $TYPE on $RUNTIME ($UDID)" >&2
      break 2
    fi
    echo "$TYPE can't run $RUNTIME" >&2
  done
done
[ -n "$UDID" ] || { echo "::error::No simulator could be created for $*" >&2; exit 1; }
xcrun simctl boot "$UDID" >&2
xcrun simctl bootstatus "$UDID" -b >&2
xcrun simctl ui "$UDID" appearance dark >&2 || true
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >&2 || true
xcrun simctl location "$UDID" set 38.5816,-121.4944 >&2 || true
xcrun simctl install "$UDID" "$APP" >&2
BID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl privacy "$UDID" grant location "$BID" >&2 || true
echo "$UDID"

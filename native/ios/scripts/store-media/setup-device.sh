#!/usr/bin/env bash
# setup-device.sh <name> <device-type-id> <runtime-id> <app-path>
# Creates and boots a fresh simulator for Store media, with a fixed status
# bar, dark appearance, a simulated location near the demo data and location
# access already granted (so no permission alert covers a capture), installs
# the app and prints the simulator's UDID.
set -euo pipefail
NAME=$1
TYPE=$2
RUNTIME=$3
APP=$4
UDID=$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME")
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

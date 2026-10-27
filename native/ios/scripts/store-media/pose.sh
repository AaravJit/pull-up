#!/usr/bin/env bash
# pose.sh <udid> fold|unfold|open: iPhone Duo simulator pose for Store media.
#
#   fold   = only the outer display powered
#   unfold = only the inner display powered
#   open   = both powered (how the simulator boots)
#
# Screen IDs from `simctl io <udid> enumerate` on Xcode 27.1 / iOS 27.1:
# 1 = outer (LCD, 1398x2034), 3 = inner (LCD-1, 2007x2853). Override with
# DUO_OUTER_DISPLAY / DUO_INNER_DISPLAY if a simulator update renumbers them.
#
# Changing a display's power while the simulator runs makes SpringBoard
# abort (-[SBMainDisplayConfigurationTransformer transformDisplayConfiguration:],
# run 40575316515), and the simulator is unusable after that. So the power is
# set and the simulator is then restarted, so SpringBoard starts in the new
# configuration. Apple's fold control (Device Hub) has no command-line
# equivalent, so a fold in the middle of a session can't be reproduced here.
set -uo pipefail
UDID=$1
POSE=$2
OUTER=${DUO_OUTER_DISPLAY:-1}
INNER=${DUO_INNER_DISPLAY:-3}
power() { echo "+ screenConfig --display=$1 power $2"; xcrun simctl io "$UDID" screenConfig --display="$1" power "$2" 2>&1; }
case "$POSE" in
  fold)   power "$OUTER" on;  power "$INNER" off ;;
  unfold) power "$INNER" on;  power "$OUTER" off ;;
  open)   power "$OUTER" on;  power "$INNER" on ;;
  *) echo "usage: pose.sh <udid> fold|unfold|open" >&2; exit 2 ;;
esac
echo "+ restart the simulator so SpringBoard starts in this configuration"
xcrun simctl shutdown "$UDID" 2>&1 | tail -2
xcrun simctl boot "$UDID" 2>&1 | tail -2
xcrun simctl bootstatus "$UDID" -b 2>&1 | tail -2
# Overrides don't survive a restart.
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>&1 | tail -2 || true
xcrun simctl ui "$UDID" appearance dark 2>&1 | tail -2 || true
xcrun simctl location "$UDID" set 38.5816,-121.4944 2>&1 | tail -2 || true
sleep 20
# Each display's power state after the restart, for the log.
xcrun simctl io "$UDID" enumerate 2>/dev/null | python3 -c '
import re, sys
text = sys.stdin.read()
for block in re.split(r"\nPort:\n", text):
    size = re.search(r"Default width: (\d+)\s+Default height: (\d+)", block)
    power = re.search(r"Power state: (\w+)", block)
    if size and size.group(1) in ("1398", "2007") and power:
        print("display %sx%s power %s" % (size.group(1), size.group(2), power.group(1)))
' || true
crashes=$(find "$HOME/Library/Logs/DiagnosticReports" -name "SpringBoard*" -mmin -3 2>/dev/null | wc -l | tr -d ' ')
echo "SpringBoard crash reports in the last 3 minutes: $crashes"

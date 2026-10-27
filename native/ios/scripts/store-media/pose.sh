#!/usr/bin/env bash
# pose.sh <udid> fold|unfold: iPhone Duo simulator pose for Store media.
# Folded = only the outer display powered; unfolded = only the inner one.
# Screen IDs from `simctl io <udid> enumerate` on Xcode 27.1 / iOS 27.1:
# 1 = outer (LCD, 1398x2034), 3 = inner (LCD-1, 2007x2853). Override with
# DUO_OUTER_DISPLAY / DUO_INNER_DISPLAY if a simulator update renumbers them.
set -uo pipefail
UDID=$1
POSE=$2
OUTER=${DUO_OUTER_DISPLAY:-1}
INNER=${DUO_INNER_DISPLAY:-3}
power() { echo "+ screenConfig --display=$1 power $2"; xcrun simctl io "$UDID" screenConfig --display="$1" power "$2" 2>&1; }
case "$POSE" in
  fold)   power "$OUTER" on;  power "$INNER" off ;;
  unfold) power "$INNER" on;  power "$OUTER" off ;;
  *) echo "usage: pose.sh <udid> fold|unfold" >&2; exit 2 ;;
esac
sleep 4
# Power state of each display, for the log.
xcrun simctl io "$UDID" enumerate 2>/dev/null | grep -E "^\s+\([0-9]+\)|Pixel Size|Power state" | head -40 || true

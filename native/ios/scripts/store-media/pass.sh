#!/usr/bin/env bash
# pass.sh <udid> <out-dir> <test> [capture_daemon.py options]
# Runs one StoreMediaUITests test against an already built app ($DD is the
# derived data path) with the capture daemon serving its requests.
set -uo pipefail
UDID=$1
OUT=$2
TEST=$3
shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
# A fresh request folder per test: a daemon must never replay an earlier
# test's requests (it would retake its screenshots over the new screen).
REQ="$OUT/requests/$TEST-$$"
mkdir -p "$REQ" "$RUNNER_TEMP/xcresults"
python3 -u "$HERE/capture_daemon.py" --udid "$UDID" --requests "$REQ" --out "$OUT" "$@" >> "$OUT/daemon.log" 2>&1 &
DAEMON=$!
cd "$HERE/../.."
echo "::group::$TEST on $UDID -> $OUT"
TEST_RUNNER_STORE_MEDIA_DIR="$REQ" ./scripts/xcodebuild-ci.sh test-without-building \
  -project PullUp.xcodeproj -scheme PullUp \
  -destination "id=$UDID" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$RUNNER_TEMP/xcresults/$(basename "$OUT")-$TEST-$$.xcresult" \
  -only-testing:"PullUpUITests/StoreMediaUITests/$TEST" \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 900 \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO
status=$?
kill "$DAEMON" 2>/dev/null
wait "$DAEMON" 2>/dev/null
tail -n 30 "$OUT/daemon.log"
echo "::endgroup::"
[ $status -eq 0 ] || echo "::error::$TEST failed on $(basename "$OUT") (xcodebuild $status)"
exit $status

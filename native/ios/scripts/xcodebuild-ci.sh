#!/usr/bin/env bash
# Runs xcodebuild with readable CI output. On failure prints only the lines
# that matter (compiler errors, failed tests) so logs stay short enough to
# read through the GitHub API.
set -uo pipefail
LOG="${RUNNER_TEMP:-/tmp}/xcodebuild-$$.log"
xcodebuild "$@" > "$LOG" 2>&1
status=$?
if command -v xcbeautify >/dev/null; then
  xcbeautify --renderer github-actions --quiet < "$LOG" || true
fi
if [ $status -ne 0 ]; then
  echo "::group::Failure summary"
  grep -E "(error|fatal error):|: error|✘|Test Case .* failed|Test .* failed|recorded an issue|Expectation failed|failed \(|BUILD FAILED|TEST FAILED|xcodebuild: error|Fatal error|[Cc]rash|unexpected exit|timed out" "$LOG" \
    | grep -v "^    " | awk '!seen[$0]++' | head -120
  # A crashed test process reports no failing test in the log; the result
  # bundle names it.
  bundle=""
  prev=""
  for arg in "$@"; do
    [ "$prev" = "-resultBundlePath" ] && bundle="$arg"
    prev="$arg"
  done
  if [ -n "$bundle" ] && [ -d "$bundle" ]; then
    xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for f in data.get("testFailures", [])[:40]:
    print("FAILED", f.get("testIdentifierString") or f.get("testName"), "--", " ".join(str(f.get("failureText", "")).split())[:400])
' || true
  fi
  echo "::endgroup::"
  echo "xcodebuild exited with $status"
fi
exit $status

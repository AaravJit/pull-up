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
  # Crash reports from this run: the reason and the crashed thread's frames.
  find "$HOME/Library/Logs/DiagnosticReports" -name "*.ips" -mmin -90 2>/dev/null | head -5 | while read -r ips; do
    echo "--- $(basename "$ips")"
    python3 - "$ips" <<'PY' || true
import json, sys
text = open(sys.argv[1], errors="replace").read()
header, _, body = text.partition("\n")
try:
    report = json.loads(body)
except ValueError:
    sys.exit(0)
print("exception:", json.dumps(report.get("exception", {})))
print("termination:", json.dumps(report.get("termination", {}))[:600])
for key, value in (report.get("asi") or {}).items():
    print("asi", key, " ".join(str(value).split())[:800])
images = report.get("usedImages", [])
for thread in report.get("threads", []):
    if not thread.get("triggered"):
        continue
    frames = thread.get("frames", [])
    # Which thread and queue crashed, then the top frames and, for a deep
    # stack, the bottom ones too, which show what started the work.
    print("  thread:", thread.get("name", ""), "queue:", thread.get("queue", ""), "frames:", len(frames))
    shown = frames if len(frames) <= 45 else frames[:30] + [None] + frames[-15:]
    for frame in shown:
        if frame is None:
            print("   ...")
            continue
        image = images[frame.get("imageIndex", 0)].get("name", "?") if images else "?"
        print("  ", image, frame.get("symbol", hex(frame.get("imageOffset", 0))), frame.get("sourceFile", ""), frame.get("sourceLine", ""))
PY
  done
  echo "::endgroup::"
  echo "xcodebuild exited with $status"
fi
exit $status

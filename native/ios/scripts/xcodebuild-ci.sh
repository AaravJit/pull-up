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
  grep -E "(error|fatal error):|: error|✘|Test Case .* failed|Test .* failed|recorded an issue|Expectation failed|failed \(|BUILD FAILED|TEST FAILED|xcodebuild: error" "$LOG" \
    | grep -v "^    " | awk '!seen[$0]++' | head -120
  echo "::endgroup::"
  echo "xcodebuild exited with $status"
fi
exit $status

#!/usr/bin/env bash
# Prints the CFBundleVersion for this run of the TestFlight workflow.
#
# App Store Connect refuses a build number it has already seen for the app,
# so every build that could be uploaded needs a new, higher one:
#
#   base   = the workflow's run number + 100. Every run of testflight.yml
#            (pull request, push or by hand) takes the next run number, so no
#            two runs share a base.
#   re-run = "<base>.<attempt>" from the second attempt on. "Re-run jobs"
#            keeps the run number, so without this a re-run after an upload
#            that went through would repeat the build number. 233.2 sorts
#            after 233 and before 234, and Apple accepts up to three
#            dot-separated integers.
#
# The first signed upload was 0.1.0 (233), run 40077637603. A base at or
# below LAST_UPLOADED_BUILD means the run number was reset (the workflow file
# was renamed or recreated), so this refuses rather than reuse a number:
# raise the offset in this file past the last upload instead.
set -euo pipefail

LAST_UPLOADED_BUILD=233
OFFSET=100

run_number="${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is not set}"
attempt="${GITHUB_RUN_ATTEMPT:-1}"
case "$run_number$attempt" in
  *[!0-9]*) echo "::error::Run number and attempt must be whole numbers (got $run_number, $attempt)." >&2; exit 1 ;;
esac

base=$(( run_number + OFFSET ))
# Only checked for builds that can be uploaded: older pull request runs had
# lower run numbers and still build unsigned archives.
if [ "${REQUIRE_NEW_BUILD:-0}" = 1 ] && [ "$base" -le "$LAST_UPLOADED_BUILD" ]; then
  echo "::error::Build $base is not above the last uploaded build $LAST_UPLOADED_BUILD. Raise OFFSET in native/ios/scripts/build-number.sh." >&2
  exit 1
fi

if [ "$attempt" -gt 1 ]; then
  echo "$base.$attempt"
else
  echo "$base"
fi

#!/usr/bin/env bash
# Checks what a Release archive claims, then writes a provenance record for
# it: provenance.json in OUT_DIR, and the same facts in the job summary.
#
#   release-provenance.sh <path to PullUp.xcarchive> <out dir>
#       Checks the archive (and the exported .ipa when IPA is set) and writes
#       the record. Exits non-zero when the app claims something it
#       shouldn't, so run it before the upload.
#   release-provenance.sh --upload <out dir>
#       After the upload: adds the upload step's outcome and altool's
#       delivery UUID to the record and the summary.
#
# Values are read back from the built app, not from the workflow inputs, so
# the record says what was actually built. The record is safe to publish
# (this repository is public): no keys, key IDs, certificates, profiles,
# team ID or Supabase key, only names and numbers anyone holding the .ipa
# could read from it.
#
# Optional environment, set by the workflow:
#   EXPECTED_VERSION, EXPECTED_BUILD   fail if the app says otherwise
#   BACKEND        staging / production (the GitHub environment used)
#   SIGNED         true when signed for App Store Connect
#   IPA            path to the exported .ipa (hashed; entitlements listed)
#   ATTESTATION_URL the build provenance attestation for the .ipa
# and with --upload:
#   UPLOAD_OUTCOME outcome of the upload step (success / failure / skipped)
#   ALTOOL_LOG     altool output, for the delivery UUID
set -euo pipefail

if [ "${1:-}" = "--upload" ]; then
  out="${2:?usage: release-provenance.sh --upload <out dir>}"
  [ -f "$out/provenance.json" ] || { echo "::error::No provenance record in $out"; exit 1; }
  delivery=""
  if [ -n "${ALTOOL_LOG:-}" ] && [ -f "$ALTOOL_LOG" ]; then
    delivery=$(grep -oE 'Delivery UUID: [0-9A-Fa-f-]+' "$ALTOOL_LOG" | head -1 | sed 's/Delivery UUID: //' || true)
  fi
  P_OUTCOME="${UPLOAD_OUTCOME:-unknown}" P_DELIVERY="$delivery" python3 -I - "$out/provenance.json" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f:
    record = json.load(f)
record["upload"] = {
    "step": os.environ["P_OUTCOME"],
    "delivery_uuid": os.environ.get("P_DELIVERY") or None,
    # altool only says Apple received the file. Processing happens later.
    "apple_processing": "not checked by this workflow; see App Store Connect > TestFlight > iOS Builds",
}
with open(sys.argv[1], "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
PY
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "Upload step: ${UPLOAD_OUTCOME:-unknown}${delivery:+, delivery \`$delivery\`}. Apple's processing isn't checked here." >> "$GITHUB_STEP_SUMMARY"
  fi
  cat "$out/provenance.json"
  exit 0
fi

archive="${1:?usage: release-provenance.sh <xcarchive> <out dir>}"
out="${2:?usage: release-provenance.sh <xcarchive> <out dir>}"
app="$archive/Products/Applications/PullUp.app"
plist="$app/Info.plist"
[ -f "$plist" ] || { echo "::error::No app in $archive"; exit 1; }
mkdir -p "$out"

read_key() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }
has_key() { plutil -extract "$1" raw -o - "$plist" >/dev/null 2>&1 || plutil -extract "$1" json -o - "$plist" >/dev/null 2>&1; }

version=$(read_key CFBundleShortVersionString)
build=$(read_key CFBundleVersion)
bundle_id=$(read_key CFBundleIdentifier)
min_os=$(read_key MinimumOSVersion)
environment_label=$(read_key PullUpBackendEnvironment)
families=$(plutil -extract UIDeviceFamily json -o - "$plist" 2>/dev/null | tr -d ' \n' || true)
background=$(plutil -extract UIBackgroundModes json -o - "$plist" 2>/dev/null | tr -d ' \n' || true)
xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)

problems=()
# Things worth a look that shouldn't stop an upload on their own.
warnings=()
[ -z "${EXPECTED_VERSION:-}" ] || [ "$version" = "$EXPECTED_VERSION" ] || problems+=("version is $version, expected $EXPECTED_VERSION")
[ -z "${EXPECTED_BUILD:-}" ] || [ "$build" = "$EXPECTED_BUILD" ] || problems+=("build is $build, expected $EXPECTED_BUILD")
# iPhone only for the first release (project.yml TARGETED_DEVICE_FAMILY).
[ "$families" = "[1]" ] || problems+=("UIDeviceFamily is ${families:-missing}, expected [1] (iPhone only)")
# Only what the app uses: location while a drive records.
[ "$background" = '["location"]' ] || problems+=("UIBackgroundModes is ${background:-missing}, expected [\"location\"]")
# No tracking: the app never asks for App Tracking Transparency.
! has_key NSUserTrackingUsageDescription || problems+=("NSUserTrackingUsageDescription is declared but the app doesn't track")
# CarPlay is not granted yet (docs/CARPLAY.md), so no CarPlay scene.
! has_key UIApplicationSceneManifest.UISceneConfigurations.CPTemplateApplicationSceneSessionRoleApplication \
  || problems+=("a CarPlay scene is declared but the CarPlay entitlement isn't granted")

ipa_sha="" ipa_bytes="" entitlements="" aps=""
if [ -n "${IPA:-}" ] && [ -f "$IPA" ]; then
  ipa_sha=$(shasum -a 256 "$IPA" | cut -d' ' -f1)
  ipa_bytes=$(wc -c < "$IPA" | tr -d " ")
  # The entitlements Apple signed into the exported app. Key names only,
  # plus the push environment: application-identifier and the team ID are
  # left out.
  unpacked=$(mktemp -d)
  unzip -q "$IPA" 'Payload/*' -d "$unpacked"
  signed_app=$(find "$unpacked/Payload" -maxdepth 1 -name '*.app' | head -1)
  codesign -d --entitlements - --xml "$signed_app" 2>/dev/null > "$unpacked/ent.plist" || true
  if [ -s "$unpacked/ent.plist" ]; then
    entitlements=$(plutil -convert json -o - "$unpacked/ent.plist" | python3 -I -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))')
    aps=$(plutil -extract aps-environment raw -o - "$unpacked/ent.plist" 2>/dev/null || true)
    case ",$entitlements," in
      *,com.apple.developer.carplay-*) problems+=("the signed app has a CarPlay entitlement") ;;
    esac
    # App Store export swaps development for production; without it pushes
    # to TestFlight and App Store installs would go to the sandbox.
    [ "$aps" = production ] || warnings+=("aps-environment in the signed app is ${aps:-missing}, expected production")
  else
    warnings+=("couldn't read the signed app's entitlements")
  fi
  rm -rf "$unpacked"
fi

export P_VERSION="$version" P_BUILD="$build" P_BUNDLE="$bundle_id" P_MINOS="$min_os" P_ENVLABEL="$environment_label" \
  P_FAMILIES="$families" P_BACKGROUND="$background" P_XCODE="$xcode" P_IPA_SHA="$ipa_sha" P_IPA_BYTES="$ipa_bytes" \
  P_ENTITLEMENTS="$entitlements" P_APS="$aps" \
  P_PROBLEMS="$(printf '%s\n' "${problems[@]+"${problems[@]}"}")" \
  P_WARNINGS="$(printf '%s\n' "${warnings[@]+"${warnings[@]}"}")"
python3 -I - "$out/provenance.json" <<'PY'
import json, os, sys
e = os.environ.get
def parsed(name):
    try:
        return json.loads(e(name, ""))
    except ValueError:
        return e(name) or None
def opt(name):
    value = e(name, "")
    return value or None
record = {
    "app": {
        "version": e("P_VERSION"), "build": e("P_BUILD"), "bundle_id": e("P_BUNDLE"),
        "minimum_os": e("P_MINOS"), "device_family": parsed("P_FAMILIES"), "background_modes": parsed("P_BACKGROUND"),
        "backend_label": opt("P_ENVLABEL"),
    },
    "source": {
        "repository": e("GITHUB_REPOSITORY"), "commit": e("GITHUB_SHA"), "ref": e("GITHUB_REF"),
        "event": e("GITHUB_EVENT_NAME"), "actor": e("GITHUB_ACTOR"),
    },
    "run": {
        "workflow": e("GITHUB_WORKFLOW"), "job": e("GITHUB_JOB"), "id": e("GITHUB_RUN_ID"),
        "number": e("GITHUB_RUN_NUMBER"), "attempt": e("GITHUB_RUN_ATTEMPT"),
        "url": f'{e("GITHUB_SERVER_URL", "https://github.com")}/{e("GITHUB_REPOSITORY")}/actions/runs/{e("GITHUB_RUN_ID")}',
        "runner": e("RUNNER_NAME"), "xcode": opt("P_XCODE"),
    },
    "environment": opt("BACKEND"),
    "signed": e("SIGNED", "false") == "true",
    "ipa": {"sha256": opt("P_IPA_SHA"), "bytes": int(e("P_IPA_BYTES")) if e("P_IPA_BYTES") else None,
            "entitlements": [k for k in e("P_ENTITLEMENTS", "").split(",") if k], "aps_environment": opt("P_APS"),
            "attestation": opt("ATTESTATION_URL")} if opt("P_IPA_SHA") else None,
    "upload": None,
    "problems": [p for p in e("P_PROBLEMS", "").splitlines() if p],
    "warnings": [w for w in e("P_WARNINGS", "").splitlines() if w],
}
with open(sys.argv[1], "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
PY

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Provenance: Pull Up $version ($build)"
    echo
    echo "| | |"
    echo "| --- | --- |"
    echo "| Commit | \`${GITHUB_SHA:-}\` (${GITHUB_REF:-}) |"
    echo "| Run | [${GITHUB_RUN_ID:-}](${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}) attempt ${GITHUB_RUN_ATTEMPT:-1}, job \`${GITHUB_JOB:-}\` |"
    echo "| Environment | ${BACKEND:-none (unsigned check)} |"
    echo "| Bundle | \`$bundle_id\`, iOS $min_os+, device family $families, background $background |"
    echo "| Signed | ${SIGNED:-false} |"
    [ -z "$xcode" ] || echo "| Xcode | $xcode |"
    [ -z "$ipa_sha" ] || echo "| .ipa SHA-256 | \`$ipa_sha\` ($ipa_bytes bytes) |"
    [ -z "$entitlements" ] || echo "| Signed entitlements | \`$(printf '%s' "$entitlements" | sed 's/,/`, `/g')\` (aps-environment $aps) |"
    [ -z "${ATTESTATION_URL:-}" ] || echo "| Attestation | $ATTESTATION_URL |"
    echo
    if [ ${#problems[@]} -gt 0 ]; then
      echo "**Problems:**"
      printf -- '- %s\n' "${problems[@]}"
    fi
    if [ ${#warnings[@]} -gt 0 ]; then
      echo "**Warnings:**"
      printf -- '- %s\n' "${warnings[@]}"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

cat "$out/provenance.json"
if [ ${#warnings[@]} -gt 0 ]; then
  for w in "${warnings[@]}"; do echo "::warning::$w"; done
fi
if [ ${#problems[@]} -gt 0 ]; then
  for p in "${problems[@]}"; do echo "::error::$p"; done
  exit 1
fi

#!/usr/bin/env bash
# Checks what a Release build claims, then writes a provenance record for
# it: provenance.json in the out dir, and the same facts in the job summary.
# With IPA set the checks run on the app inside the exported, signed .ipa.
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
#   IPA            path to the exported .ipa: checked instead of the
#                  archive, hashed, and its signed entitlements checked
#   EXPECTED_BUNDLE_ID  default app.pullup.ios
#   EXPECTED_MIN_OS     default 18.0
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
[ -f "$app/Info.plist" ] || { echo "::error::No app in $archive"; exit 1; }
mkdir -p "$out"

problems=()
# Things worth a look that shouldn't stop an upload on their own.
warnings=()

# With IPA set, every check below runs on the app inside the exported,
# signed .ipa: exactly what Apple receives, not the project settings.
ipa_sha="" ipa_bytes=""
if [ -n "${IPA:-}" ]; then
  [ -f "$IPA" ] || { echo "::error::No .ipa at $IPA"; exit 1; }
  ipa_sha=$(shasum -a 256 "$IPA" | cut -d' ' -f1)
  ipa_bytes=$(wc -c < "$IPA" | tr -d " ")
  unpacked=$(mktemp -d)
  trap 'rm -rf "$unpacked"' EXIT
  unzip -q "$IPA" 'Payload/*' -d "$unpacked"
  app=$(find "$unpacked/Payload" -maxdepth 1 -name '*.app' | head -1)
  [ -n "$app" ] && [ -f "$app/Info.plist" ] || { echo "::error::No app inside $IPA"; exit 1; }
fi
plist="$app/Info.plist"

read_key() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }
has_key() { plutil -extract "$1" raw -o - "$plist" >/dev/null 2>&1 || plutil -extract "$1" json -o - "$plist" >/dev/null 2>&1; }

version=$(read_key CFBundleShortVersionString)
build=$(read_key CFBundleVersion)
bundle_id=$(read_key CFBundleIdentifier)
min_os=$(read_key MinimumOSVersion)
environment_label=$(read_key PullUpBackendEnvironment)
families=$(plutil -extract UIDeviceFamily json -o - "$plist" 2>/dev/null | tr -d ' \n' || true)
background=$(plutil -extract UIBackgroundModes json -o - "$plist" 2>/dev/null | tr -d ' \n' || true)
scenes=$(plutil -extract UIApplicationSceneManifest json -o - "$plist" 2>/dev/null | tr -d '\n' || true)
xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)

[ -z "${EXPECTED_VERSION:-}" ] || [ "$version" = "$EXPECTED_VERSION" ] || problems+=("CFBundleShortVersionString is ${version:-missing}, expected $EXPECTED_VERSION")
[ -z "${EXPECTED_BUILD:-}" ] || [ "$build" = "$EXPECTED_BUILD" ] || problems+=("CFBundleVersion is ${build:-missing}, expected $EXPECTED_BUILD")
expected_bundle="${EXPECTED_BUNDLE_ID:-app.pullup.ios}"
[ "$bundle_id" = "$expected_bundle" ] || problems+=("CFBundleIdentifier is ${bundle_id:-missing}, expected $expected_bundle")
expected_min_os="${EXPECTED_MIN_OS:-18.0}"
[ "$min_os" = "$expected_min_os" ] || problems+=("MinimumOSVersion is ${min_os:-missing}, expected $expected_min_os")
# iPhone only for the first release (project.yml TARGETED_DEVICE_FAMILY).
[ "$families" = "[1]" ] || problems+=("UIDeviceFamily is ${families:-missing}, expected [1] (iPhone only)")
# Only what the app uses: location while a drive records.
[ "$background" = '["location"]' ] || problems+=("UIBackgroundModes is ${background:-missing}, expected [\"location\"]")
# No tracking: the app never asks for App Tracking Transparency.
! has_key NSUserTrackingUsageDescription || problems+=("NSUserTrackingUsageDescription is declared but the app doesn't track")
# CarPlay is not granted yet (docs/CARPLAY.md), so no CarPlay scene.
case "$scenes" in
  *CPTemplate*|*CarPlay*) problems+=("the scene manifest declares CarPlay but the CarPlay entitlement isn't granted") ;;
esac
# App Store Connect rejects an app without its privacy manifest.
privacy_manifest=false
if [ -f "$app/PrivacyInfo.xcprivacy" ]; then
  privacy_manifest=true
  plutil -lint "$app/PrivacyInfo.xcprivacy" >/dev/null 2>&1 || problems+=("PrivacyInfo.xcprivacy isn't a valid property list")
else
  problems+=("PrivacyInfo.xcprivacy is missing from the app")
fi
# The public pages (LegalLinks): set, expanded, and written without the
# scheme, as Base.xcconfig has them.
links=()
for key in PullUpPrivacyPolicyURL PullUpSupportURL PullUpTermsURL PullUpCommunityURL; do
  value=$(read_key "$key")
  case "$value" in
    "") problems+=("$key is empty, so the app shows no link") ;;
    '$('*|*://*|*" "*) problems+=("$key is '$value', expected a host and path without https://") ;;
    *.*) links+=("$key=https://$value") ;;
    *) problems+=("$key is '$value', expected a host and path without https://") ;;
  esac
done

entitlements="" aps=""
if [ -n "$ipa_sha" ]; then
  # The entitlements Apple signed into the exported app. Only names and the
  # push environment are recorded: application-identifier, the team ID and
  # keychain groups are left out.
  codesign -d --entitlements - --xml "$app" > "$unpacked/ent.plist" 2>/dev/null || true
  if [ ! -s "$unpacked/ent.plist" ]; then
    codesign -d --entitlements :- "$app" > "$unpacked/ent.raw" 2>/dev/null || true
    # Older output can carry a binary blob header before the XML.
    python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); i=d.find(b"<?xml"); open(sys.argv[2],"wb").write(d[i:] if i >= 0 else b"")' \
      "$unpacked/ent.raw" "$unpacked/ent.plist" 2>/dev/null || true
  fi
  if [ -s "$unpacked/ent.plist" ] && plutil -convert json -o "$unpacked/ent.json" "$unpacked/ent.plist" 2>/dev/null; then
    # Allowed: what signing always adds, plus the two capabilities Pull Up
    # uses (Sign in with Apple, push). Anything else, CarPlay included,
    # fails the job: add a key here only together with the feature using it.
    report=$(python3 -I - "$unpacked/ent.json" <<'PY'
import json, sys
ent = json.load(open(sys.argv[1]))
signing = {"application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
           "get-task-allow", "beta-reports-active"}
used = {"aps-environment", "com.apple.developer.applesignin"}
print("KEYS " + ",".join(sorted(ent)))
print("APS " + str(ent.get("aps-environment", "")))
for key in sorted(set(ent) - signing - used):
    what = "a CarPlay entitlement" if key.startswith("com.apple.developer.carplay") else "an entitlement the app doesn't use"
    print(f"PROBLEM the signed app has {what}: {key}")
if ent.get("aps-environment") != "production":
    print(f"PROBLEM aps-environment in the signed app is {ent.get('aps-environment') or 'missing'}, expected production")
if "Default" not in (ent.get("com.apple.developer.applesignin") or []):
    print("PROBLEM Sign in with Apple (com.apple.developer.applesignin Default) is missing from the signed app")
if ent.get("get-task-allow") is True:
    print("PROBLEM get-task-allow is true: a debug-signed app, not an App Store one")
PY
)
    entitlements=$(printf '%s\n' "$report" | sed -n 's/^KEYS //p')
    aps=$(printf '%s\n' "$report" | sed -n 's/^APS //p')
    while IFS= read -r line; do
      [ -n "$line" ] && problems+=("$line")
    done < <(printf '%s\n' "$report" | sed -n 's/^PROBLEM //p')
  else
    problems+=("couldn't read the signed app's entitlements with codesign")
  fi
fi

export P_VERSION="$version" P_BUILD="$build" P_BUNDLE="$bundle_id" P_MINOS="$min_os" P_ENVLABEL="$environment_label" \
  P_FAMILIES="$families" P_BACKGROUND="$background" P_XCODE="$xcode" P_IPA_SHA="$ipa_sha" P_IPA_BYTES="$ipa_bytes" \
  P_ENTITLEMENTS="$entitlements" P_APS="$aps" P_PRIVACY_MANIFEST="$privacy_manifest" P_LINKS="$(printf '%s\n' "${links[@]+"${links[@]}"}")" \
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
        "public_pages": dict(l.split("=", 1) for l in e("P_LINKS", "").splitlines() if "=" in l),
        "privacy_manifest": e("P_PRIVACY_MANIFEST") == "true",
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

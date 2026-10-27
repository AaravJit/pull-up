#!/usr/bin/env bash
# Puts the committed package versions into the generated project, so the app
# builds with exactly the supabase-swift (and dependency) versions recorded in
# native/ios/Package.resolved. Run it after `xcodegen generate`; CI does, and
# passes -disableAutomaticPackageResolution so xcodebuild fails instead of
# quietly picking newer versions.
#
# PullUp.xcodeproj is generated and ignored by git, so its own
# Package.resolved isn't kept. PullUpKit's tests use
# native/ios/Packages/PullUpKit/Package.resolved, which is committed as is.
#
# To move to newer versions: in Xcode, File ▸ Packages ▸ Update to Latest
# Package Versions, then copy
# PullUp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# back to native/ios/Package.resolved, and update PullUpKit's file the same
# way (`swift package update` in native/ios/Packages/PullUpKit).
set -euo pipefail
cd "$(dirname "$0")/.."
src=Package.resolved
dst=PullUp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [ ! -f "$src" ]; then
  echo "::error::native/ios/Package.resolved is missing" >&2
  exit 1
fi
if [ ! -d PullUp.xcodeproj ]; then
  echo "::error::PullUp.xcodeproj not found; run xcodegen generate first" >&2
  exit 1
fi
mkdir -p "$(dirname "$dst")"
cp "$src" "$dst"
python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
for p in d.get("pins", []):
    s=p.get("state", {})
    print("pinned", p.get("identity"), s.get("version") or s.get("branch") or "", s.get("revision", "")[:12])' "$dst"

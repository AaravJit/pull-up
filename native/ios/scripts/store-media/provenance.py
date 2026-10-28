#!/usr/bin/env python3
"""Records where Store media came from: commit, workflow run, Xcode and SDK,
the app build, and each simulator (device type, iOS runtime and build, the
screens simctl reports). Writes <media>/provenance.json.

  provenance.py <media-dir> <PullUp.app> label=UDID [label=UDID ...]
"""
import json
import os
import plistlib
import re
import subprocess
import sys


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def main():
    media, app = sys.argv[1], sys.argv[2]
    devices_json = json.loads(sh("xcrun", "simctl", "list", "devices", "-j") or "{}")
    runtimes = {r["identifier"]: r for r in json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j") or "{}").get("runtimes", [])}
    info = {}
    try:
        with open(os.path.join(app, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except OSError:
        pass
    record = {
        "commit": os.environ.get("GITHUB_SHA"),
        "ref": os.environ.get("GITHUB_REF_NAME"),
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "job": os.environ.get("GITHUB_JOB"),
        "runner": {"os": sh("sw_vers"), "label": "xcode-27"},
        "xcode": sh("xcodebuild", "-version"),
        "app": {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                                               "DTSDKName", "DTPlatformVersion", "DTXcode", "DTXcodeBuild", "PullUpProOffered")},
        "configuration": "Debug (simulator); launch arguments -PullUpDemo -PullUpResetDefaults -PullUpStoreCapture -PullUpAppearance dark",
        "devices": {},
    }
    for pair in sys.argv[3:]:
        label, _, udid = pair.partition("=")
        if not udid:
            continue
        entry = {"udid": udid}
        for runtime_id, devs in devices_json.get("devices", {}).items():
            for d in devs:
                if d["udid"] == udid:
                    rt = runtimes.get(runtime_id, {})
                    entry.update({"name": d["name"], "device_type": d.get("deviceTypeIdentifier"), "runtime": runtime_id,
                                  "ios": rt.get("version"), "ios_build": rt.get("buildversion")})
        screens = []
        text = sh("xcrun", "simctl", "io", udid, "enumerate")
        for m in re.finditer(r"\((\d+)\) ([^:\n]+):\s*\n(?:.*\n)*?\s+Pixel Size: \{(\d+), (\d+)\}", text):
            screens.append({"id": int(m.group(1)), "name": m.group(2).strip(), "pixels": [int(m.group(3)), int(m.group(4))]})
        entry["screens"] = screens
        record["devices"][label] = entry
    os.makedirs(media, exist_ok=True)
    with open(os.path.join(media, "provenance.json"), "w") as f:
        json.dump(record, f, indent=1)
    print(json.dumps(record, indent=1))


if __name__ == "__main__":
    main()

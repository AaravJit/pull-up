#!/usr/bin/env python3
"""Turns the raw simulator recordings under <root> (any */video-raw/*.mov)
into App Store Connect app previews and checks each against Apple's app
preview specification (developer.apple.com/help/app-store-connect/reference/
app-information/app-preview-specifications):

  886 x 1920 portrait (1920 x 886 landscape), H.264 High Profile up to
  Level 4.0, progressive, 30 fps, 10-12 Mbps, stereo AAC 256 kbps 48 kHz,
  15-30 seconds, at most 500 MB.

The picture is only ever scaled uniformly. A recording a touch taller than
886:1920 (iPhone with Dynamic Island) loses a few rows top and bottom; a
wider one (iPhone Duo's displays) is centred on black, never stretched.
The audio track is silence. Writes <name>.mp4 to video-upload/, stills to
video-stills/ and ffprobe reports plus a pass/fail check to video-probe/.

  encode.py <root>
"""
import glob
import json
import os
import subprocess
import sys

MAX_SECONDS = 29.5
MIN_SECONDS = 15.0


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def encode(src):
    pass_dir = os.path.dirname(os.path.dirname(src))
    name = os.path.splitext(os.path.basename(src))[0]
    for sub in ("video-upload", "video-stills", "video-probe"):
        os.makedirs(os.path.join(pass_dir, sub), exist_ok=True)
    raw = probe(src)
    with open(os.path.join(pass_dir, "video-probe", name + ".raw.json"), "w") as f:
        json.dump(raw, f, indent=1)
    video = next(s for s in raw["streams"] if s["codec_type"] == "video")
    w, h = int(video["width"]), int(video["height"])
    duration = float(raw["format"]["duration"])
    tw, th = (886, 1920) if h >= w else (1920, 886)
    if w / h <= tw / th:
        # Taller than the target: fit the width, trim the few extra rows.
        sh = int(round(h * tw / w / 2)) * 2
        geometry = "scale=%d:%d:flags=lanczos:out_color_matrix=bt709:out_range=tv,crop=%d:%d" % (tw, sh, tw, th)
        note = "scaled %dx%d -> %dx%d (uniform), cropped %d px total top/bottom" % (w, h, tw, sh, sh - th)
    else:
        # Wider than the target: fit the width, centre on black.
        sh = int(round(h * tw / w / 2)) * 2
        geometry = ("scale=%d:%d:flags=lanczos:out_color_matrix=bt709:out_range=tv,pad=%d:%d:0:(oh-ih)/2:color=black"
                    % (tw, sh, tw, th))
        note = "scaled %dx%d -> %dx%d (uniform), centred on a %dx%d black frame" % (w, h, tw, sh, tw, th)
    length = min(duration, MAX_SECONDS)
    out = os.path.join(pass_dir, "video-upload", name + ".mp4")
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", src,
        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-map", "0:v:0", "-map", "1:a:0", "-t", "%.3f" % length,
        "-vf", "fps=30," + geometry + ",setsar=1,format=yuv420p",
        "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-level:v", "4.0",
        "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "11M",
        "-x264-params", "nal-hrd=cbr:force-cfr=1", "-g", "60", "-r", "30",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart",
        out,
    ]
    subprocess.run(cmd, check=True)
    result = probe(out)
    with open(os.path.join(pass_dir, "video-probe", name + ".json"), "w") as f:
        json.dump(result, f, indent=1)
    v = next(s for s in result["streams"] if s["codec_type"] == "video")
    a = [s for s in result["streams"] if s["codec_type"] == "audio"]
    out_duration = float(result["format"]["duration"])
    checks = {
        "size %dx%d" % (tw, th): (int(v["width"]), int(v["height"])) == (tw, th),
        "codec h264": v["codec_name"] == "h264",
        "High profile": v.get("profile") == "High",
        "level <= 4.0": int(v.get("level", 99)) <= 40,
        "progressive": v.get("field_order", "progressive") in ("progressive", "unknown"),
        "30 fps": v.get("r_frame_rate") == "30/1" and v.get("avg_frame_rate") == "30/1",
        "video 10-12 Mbps": 10_000_000 <= int(v.get("bit_rate", 0)) <= 12_000_000,
        "duration 15-30 s": MIN_SECONDS <= out_duration <= 30.0,
        "stereo AAC 48 kHz": len(a) == 1 and a[0]["codec_name"] == "aac" and int(a[0]["channels"]) == 2 and a[0]["sample_rate"] == "48000",
        "audio ~256 kbps": len(a) == 1 and 240_000 <= int(a[0].get("bit_rate", 0)) <= 270_000,
        "<= 500 MB": os.path.getsize(out) <= 500 * 1024 * 1024,
    }
    report = {
        "source": os.path.relpath(src, pass_dir), "source_size": [w, h], "source_seconds": round(duration, 3),
        "file": os.path.relpath(out, pass_dir), "size": [int(v["width"]), int(v["height"])],
        "seconds": round(out_duration, 3), "fps": v.get("avg_frame_rate"), "codec": v["codec_name"],
        "profile": v.get("profile"), "level": v.get("level"), "video_bit_rate": int(v.get("bit_rate", 0)),
        "audio": [{"codec": s["codec_name"], "channels": s["channels"], "sample_rate": s["sample_rate"],
                   "bit_rate": int(s.get("bit_rate", 0))} for s in a],
        "bytes": os.path.getsize(out), "geometry": note,
        "checks": checks, "compliant": all(checks.values()),
    }
    with open(os.path.join(pass_dir, "video-probe", name + ".check.json"), "w") as f:
        json.dump(report, f, indent=1)
    for i, t in enumerate([1.0, out_duration * 0.25, out_duration * 0.5, out_duration * 0.75, out_duration - 1.0]):
        subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-ss", "%.2f" % t, "-i", out,
                        "-frames:v", "1", os.path.join(pass_dir, "video-stills", "%s-%d.png" % (name, i))], check=True)
    print(json.dumps({k: report[k] for k in ("file", "size", "seconds", "video_bit_rate", "geometry", "compliant")}))
    return report


def main():
    root = sys.argv[1]
    sources = sorted(glob.glob(os.path.join(root, "**", "video-raw", "*.mov"), recursive=True))
    if not sources:
        print("No recordings under", root)
        return 0
    reports = [encode(s) for s in sources]
    bad = [r["file"] for r in reports if not r["compliant"]]
    for b in bad:
        print("::warning::%s doesn't meet the app preview spec; see its .check.json" % b)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Host side of StoreMediaUITests: takes the screenshots and screen
recordings the UI test asks for, with simctl, on the right display.

The test writes req-<id>.json into --requests; this answers with
ack-<id>.json once the capture is on disk. Every request is logged, with the
app window size the test saw, to <out>/captures.jsonl.

  capture_daemon.py --udid UDID --requests DIR --out DIR [--display N]
                    [--fold-display N --unfold-display N]

--display is the simctl screen ID to capture (omit for a single-display
iPhone). On iPhone Duo, fold/unfold requests switch which display is powered
(scripts/store-media/pose.sh) and which one is captured.
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone


def now():
    return datetime.now(timezone.utc).isoformat()


class Daemon:
    def __init__(self, args):
        self.udid = args.udid
        self.requests = args.requests
        self.out = args.out
        self.display = args.display
        self.fold_display = args.fold_display
        self.unfold_display = args.unfold_display
        self.pose = args.pose
        self.recording = None  # (name, process, stderr lines, started)
        self.handled = set()
        os.makedirs(os.path.join(self.out, "screenshots"), exist_ok=True)
        os.makedirs(os.path.join(self.out, "video-raw"), exist_ok=True)
        self.log_path = os.path.join(self.out, "captures.jsonl")

    def log(self, entry):
        entry["at"] = now()
        with open(self.log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")
        print(json.dumps(entry), flush=True)

    def display_args(self):
        return ["--display=%s" % self.display] if self.display else []

    def run(self, cmd, timeout=120):
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()

    def shot(self, name):
        path = os.path.join(self.out, "screenshots", name + ".png")
        cmd = ["xcrun", "simctl", "io", self.udid, "screenshot", "--type=png", "--mask=ignored"] + self.display_args() + [path]
        for attempt in range(3):
            code, output = self.run(cmd)
            if code == 0 and os.path.exists(path):
                return {"file": os.path.relpath(path, self.out), "cmd": " ".join(cmd[4:])}
            time.sleep(2)
        raise RuntimeError("screenshot failed: %s" % output)

    def rec_start(self, name):
        if self.recording:
            raise RuntimeError("already recording %s" % self.recording[0])
        path = os.path.join(self.out, "video-raw", name + ".mov")
        cmd = ["xcrun", "simctl", "io", self.udid, "recordVideo", "--codec=h264", "--mask=ignored", "--force"] + self.display_args() + [path]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines = []
        started = threading.Event()

        def reader():
            for line in proc.stdout:
                lines.append(line.rstrip())
                if "Recording started" in line:
                    started.set()

        threading.Thread(target=reader, daemon=True).start()
        if not started.wait(60):
            proc.send_signal(signal.SIGINT)
            raise RuntimeError("recording didn't start: %s" % " | ".join(lines))
        self.recording = (name, proc, lines, time.time(), path)
        return {"file": os.path.relpath(path, self.out), "cmd": " ".join(cmd[4:])}

    def rec_stop(self, name):
        if not self.recording:
            raise RuntimeError("not recording")
        rec_name, proc, lines, started, path = self.recording
        self.recording = None
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(120)
        except subprocess.TimeoutExpired:
            proc.kill()
            raise RuntimeError("recording didn't finish")
        if not os.path.exists(path):
            raise RuntimeError("no video written: %s" % " | ".join(lines))
        return {"file": os.path.relpath(path, self.out), "seconds": round(time.time() - started, 2),
                "bytes": os.path.getsize(path), "simctl": lines[-5:]}

    def set_pose(self, pose):
        here = os.path.dirname(os.path.abspath(__file__))
        code, output = self.run([os.path.join(here, "pose.sh"), self.udid, pose], timeout=120)
        if code != 0:
            raise RuntimeError("pose %s failed: %s" % (pose, output))
        self.pose = pose
        self.display = self.fold_display if pose == "fold" else self.unfold_display
        return {"pose": pose, "display": self.display, "output": output[-2000:]}

    def handle(self, req):
        action = req.get("action")
        name = req.get("name", "")
        if action == "shot":
            return self.shot(name)
        if action == "recstart":
            return self.rec_start(name)
        if action == "recstop":
            return self.rec_stop(name)
        if action in ("fold", "unfold"):
            if not self.fold_display:
                raise RuntimeError("not a foldable")
            return self.set_pose(action)
        if action == "note":
            return {}
        raise RuntimeError("unknown action %s" % action)

    def loop(self):
        print("capture daemon: udid=%s display=%s pose=%s" % (self.udid, self.display, self.pose), flush=True)
        while True:
            names = sorted(n for n in os.listdir(self.requests) if n.startswith("req-") and n.endswith(".json"))
            for n in names:
                if n in self.handled:
                    continue
                self.handled.add(n)
                path = os.path.join(self.requests, n)
                try:
                    with open(path) as f:
                        req = json.load(f)
                except (OSError, ValueError) as e:
                    req = {"id": n[4:-5], "action": "?", "error": str(e)}
                entry = dict(req)
                entry.update({"display": self.display, "pose": self.pose, "device": self.udid})
                try:
                    entry.update(self.handle(req))
                    entry["ok"] = True
                except Exception as e:  # noqa: BLE001 - reported to the test
                    entry["ok"] = False
                    entry["error"] = str(e)
                self.log(entry)
                ack = os.path.join(self.requests, "ack-%s.json" % req.get("id", n[4:-5]))
                with open(ack + ".tmp", "w") as f:
                    json.dump({"ok": entry["ok"], "error": entry.get("error", "")}, f)
                os.replace(ack + ".tmp", ack)
            time.sleep(0.2)

    def shutdown(self, *_):
        if self.recording:
            self.recording[1].send_signal(signal.SIGINT)
            try:
                self.recording[1].wait(60)
            except subprocess.TimeoutExpired:
                pass
        sys.exit(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--requests", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--display")
    ap.add_argument("--fold-display")
    ap.add_argument("--unfold-display")
    ap.add_argument("--pose", default="")
    args = ap.parse_args()
    os.makedirs(args.requests, exist_ok=True)
    daemon = Daemon(args)
    signal.signal(signal.SIGTERM, daemon.shutdown)
    signal.signal(signal.SIGINT, daemon.shutdown)
    daemon.loop()


if __name__ == "__main__":
    main()

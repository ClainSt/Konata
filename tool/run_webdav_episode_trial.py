"""Run the opt-in, real WebDAV parity test from the CCPlayer repo on Windows."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 18879


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--device", required=True, help="ADB device serial")
    parser.add_argument("--flutter", default="flutter.bat")
    parser.add_argument("--adb", default="adb.exe")
    parser.add_argument("--output", type=Path, required=True, help="New results directory")
    parser.add_argument("--usb-handoff", action="store_true", required=True,
                        help="Deliver this source's temporary login to the isolated Android test app")
    parser.add_argument("--mode", choices=["episode","cache-trials","subtitle-check","latency","sdr","android-retest"],
                        default="episode", help="Use diagnostic modes after the full byte check")
    parser.add_argument("--verified-video-sha256",
                        help="Previously verified FULL remote digest; repeat checks rehash the local copy and compare three remote ranges")
    parser.add_argument("--switch-unix", type=int, default=0)
    parser.add_argument("--stop-unix", type=int, default=0)
    parser.add_argument("--video-rate", type=int, default=0, help="Test-only video payload cap in bytes/s for cache trials")
    parser.add_argument("--font-probe",action="store_true",help="Capture ASS glyph selections and same-frame masks")
    parser.add_argument("--font-tc",action="store_true",help="Compare the phone-specific MiSans TC font in isolation")
    parser.add_argument("--font-profile",action="store_true",help="Use the installed Windows subtitle profile in the isolated font probe")
    parser.add_argument("--sdr-extra",action="store_true",help="Repeat motion sections and check a second dark gradient")
    parser.add_argument("--sdr-gradients",action="store_true",help="Check additional Android dark gradients")
    args = parser.parse_args()
    video = args.video.resolve(strict=True)
    files = {"video": video, "sc": video.with_suffix(".sc.ass"),
             "tc": video.with_suffix(".tc.ass")}
    for path in files.values():
        if not path.is_file():
            parser.error(f"Missing local reference: {path.name}")
    if args.verified_video_sha256:
        with video.open("rb") as src:
            if hashlib.file_digest(src, "sha256").hexdigest() != args.verified_video_sha256.lower():
                parser.error("The previous full digest does not match the local file")
    args.output.mkdir(parents=True, exist_ok=False)
    token = secrets.token_urlsafe(40)
    permit = ("Bearer " + token).encode()
    handoff = None
    consumed = False
    lock = threading.Lock()
    android_done = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def authorize(self):
            actual = self.headers.get("Authorization", "").encode()
            if hmac.compare_digest(actual, permit):
                return True
            self.reply(403)
            return False

        def reply(self, status, data=b""):
            self.send_response(status)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            nonlocal handoff, consumed
            if not self.authorize():
                return
            route = self.path.lstrip("/")
            if route == "handoff":
                with lock:
                    data, handoff = handoff, None
                    if data:
                        consumed = True
                self.reply(200, data) if data else self.reply(204)
            elif route == "weak-band":
                status = subprocess.check_output(adb + ["shell", "cmd", "wifi", "status"], text=True, errors="replace")
                freq = re.search(r"Frequency:\s*(\d+)MHz", status)
                self.reply(200 if freq and 2400 <= int(freq[1]) < 2500 else 204)
            elif route == "android-done":
                self.reply(200 if android_done.is_set() else 204)
            elif route in files:
                path = files[route]
                self.send_response(200)
                self.send_header("Content-Length", str(path.stat().st_size))
                self.end_headers()
                with path.open("rb") as src:
                    shutil.copyfileobj(src, self.wfile, 256 * 1024)
            else:
                self.reply(404)

        def do_POST(self):
            nonlocal handoff
            if not self.authorize():
                return
            if self.path == "/android-done":
                android_done.set()
                self.reply(204)
                return
            if self.path != "/handoff":
                self.reply(404)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 16384:
                self.reply(413)
                return
            data = self.rfile.read(size)
            with lock:
                if consumed or handoff is not None:
                    self.reply(409)
                    return
                handoff = data
            self.reply(204)

    statuses = {}
    env = dict(os.environ, CCPLAYER_ISOLATED_VALIDATION="1")
    adb = [args.adb, "-s", args.device]
    root = Path(__file__).resolve().parent.parent
    def run(device, label, test, config, timeout):
        command = [args.flutter, "test", "--no-pub", "-d", device, test,
                   f"--dart-define-from-file={config}", "--reporter", "expanded",
                   "--timeout", timeout]
        with (args.output / f"{label}.jsonl").open("x", encoding="utf-8") as result:
            with subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                                  errors="replace") as proc:
                for line in proc.stdout:
                    # Never persist raw exception messages, paths, auth or media tickets.
                    clean = line.strip()
                    if (clean.startswith(("The following ", "TimeoutException", "Lost connection",
                                          "Expected:", "Actual:", "Bad state:", "Error: ADB",
                                          "Failure [INSTALL_FAILED", "All tests passed!"))
                            and len(clean) < 210 and not any(c in clean for c in '{}/@')):
                        print(label, clean, flush=True)
                        result.write(json.dumps({"diagnostic": clean}) + "\n")
                        result.flush()
                    frame = re.search(r"(integration_test/[a-z_]+\.dart:\d+:\d+)", clean)
                    if frame and clean.startswith("#"):
                        result.write(json.dumps({"test_stack": frame.group(1)}) + "\n")
                        result.flush()
                    for marker in ("DAV_TRIAL ", "DAV_BYTE_PROOF "):
                        if line.startswith(marker):
                            data = json.loads(line[len(marker):])
                            result.write(json.dumps(data) + "\n")
                            result.flush()
                            print(label, data.get("event", "byte_proof"), flush=True)
                statuses[label] = proc.wait()

    with tempfile.TemporaryDirectory() as temporary:
        config = Path(temporary) / "defines.json"
        config.write_text(json.dumps({"DAV_LOCAL_VIDEO": str(video),
                                     "DAV_EPISODE_NAME": video.name,
                                     "DAV_LOCAL_DIR": str(video.parent),
                                     "DAV_VERIFIED_VIDEO_SHA256": (args.verified_video_sha256 or "").lower(),
                                     "DAV_SWITCH_UNIX": str(args.switch_unix), "DAV_STOP_UNIX": str(args.stop_unix),
                                     "DAV_SDR_GRADIENTS": str(args.sdr_gradients).lower(),
                                     "DAV_FONT_TC": str(args.font_tc).lower(),
                                     "DAV_FONT_PROBE": str(args.font_probe).lower(),
                                     "DAV_FONT_PROFILE": str(args.font_profile).lower(),
                                     "DAV_SDR_EXTRA": str(args.sdr_extra).lower(),
                                     "DAV_SDR": str(args.mode == "sdr").lower(),
                                     "DAV_LATENCY": str(args.mode == "latency").lower(),
                                     "DAV_SUB_CHECK": str(args.mode == "subtitle-check").lower(),
                                     "DAV_CAP_BYTES_PER_SECOND": str(args.video_rate),
                                     "DAV_CACHE_TRIALS": str(args.mode in ("cache-trials","subtitle-check","latency")).lower(),
                                     "DAV_ANDROID_RETEST": str(args.mode == "android-retest").lower(),
                                     "DAV_USB_TOKEN": token}), encoding="utf-8")
        if args.mode == "episode" and not args.verified_video_sha256:
            run("windows", "byte-check", "integration_test/webdav_byte_parity_test.dart",
                config, "25m")
        if statuses.get("byte-check", 0):
            raise SystemExit("Byte verification failed")
        with ThreadingHTTPServer(("127.0.0.1", PORT), Handler) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            forwards = subprocess.check_output(adb + ["reverse", "--list"], text=True)
            if f"tcp:{PORT}" in forwards:
                raise SystemExit("Test reverse port is already in use")
            subprocess.run(adb + ["reverse", f"tcp:{PORT}", f"tcp:{PORT}"], check=True)
            try:
                threads = [threading.Thread(target=run, args=(device, label,
                           "integration_test/webdav_episode_parity_test.dart",
                           config, "100m")) for device, label in
                           [("windows", "windows"), (args.device, "android")]]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()
            finally:
                subprocess.run(adb + ["reverse", "--remove", f"tcp:{PORT}"])
                server.shutdown()
                handoff = None
    if any(statuses.get(label, 1) for label in ["windows", "android"]):
        raise SystemExit("Incomplete trial. Inspect saved measurement events.")


if __name__ == "__main__":
    main()

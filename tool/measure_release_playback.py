"""Read a bounded mpv JSON IPC trace from an unmodified running release."""

import argparse
from contextlib import ExitStack
import ctypes
import json
import os
from pathlib import Path
import select
import socket
import time


CONFIG = (
    "mpv-version", "duration", "hwdec-current", "video-params/pixelformat",
    "video-params/primaries", "video-params/gamma", "video-params/colorlevels",
    "current-vo", "scale", "dscale", "osd-width", "osd-height", "sid",
)
STATES = ("paused-for-cache", "seeking", "pause", "eof-reached")
SAMPLES = ("time-pos", "frame-drop-count", "decoder-frame-drop-count", "avsync",
           "demuxer-cache-state", "cache-speed")


def measure(args):
    with ExitStack() as stack:
        server_pid = None
        if args.pipe:
            import msvcrt
            stream = stack.enter_context(open(r"\\.\pipe" + "\\" + args.pipe, "r+b", buffering=0))
            pid = ctypes.c_ulong()
            handle = ctypes.c_void_p(msvcrt.get_osfhandle(stream.fileno()))
            if not ctypes.windll.kernel32.GetNamedPipeServerProcessId(handle, ctypes.byref(pid)):
                raise ctypes.WinError()
            server_pid = pid.value
            if args.pid and server_pid != args.pid:
                raise ValueError("Named pipe belongs to a different process")
            def ready(timeout):
                available = ctypes.c_ulong()
                until = time.monotonic() + timeout
                while True:
                    if not ctypes.windll.kernel32.PeekNamedPipe(
                        handle, None, 0, None, ctypes.byref(available), None
                    ):
                        raise ctypes.WinError()
                    if available.value:
                        return True
                    left = until - time.monotonic()
                    if left <= 0:
                        return False
                    time.sleep(min(left, 0.02))
        else:
            sock = stack.enter_context(socket.create_connection(("127.0.0.1", args.port), timeout=5))
            sock.settimeout(None)
            stream = stack.enter_context(sock.makefile("rwb", buffering=0))
            def ready(timeout):
                return bool(select.select([sock], [], [], timeout)[0])

        output = stack.enter_context(args.output.open("x", encoding="utf-8"))
        start = time.monotonic()

        def record(**fields):
            output.write(json.dumps({"ms": round((time.monotonic() - start) * 1000), **fields}) + "\n")
            output.flush()

        names = CONFIG + STATES + SAMPLES

        def request(command, name):
            index = names.index(name) + 1
            args = [command, index, name] if command == "observe_property" else [command, name]
            stream.write((json.dumps({"command": args, "request_id": index}) + "\n").encode())

        record(event="connected", server_pid=server_pid, interval_s=1)
        def finish_on_disconnect(exc_type, exc, traceback):
            if isinstance(exc, (BrokenPipeError, ConnectionResetError)) or getattr(exc, "winerror", None) in (109, 232):
                record(event="disconnected")
        stack.push(finish_on_disconnect)
        for name in CONFIG:
            request("get_property", name)
        for name in STATES:
            request("observe_property", name)
        next_sample = start
        deadline = start + args.seconds
        while time.monotonic() < deadline:
            if time.monotonic() >= next_sample:
                for name in SAMPLES:
                    request("get_property", name)
                next_sample = time.monotonic() + 1
            if not ready(max(0, min(next_sample, deadline) - time.monotonic())):
                continue
            line = stream.readline()
            if not line:
                record(event="disconnected")
                return False
            item = json.loads(line)
            event = item.get("event")
            if event == "end-file":
                record(event=event, reason=item.get("reason"))
                return item.get("reason") == "eof"
            if event in ("file-loaded", "playback-restart"):
                record(event=event)
                if event == "file-loaded":
                    for name in CONFIG:
                        request("get_property", name)
                continue
            if event == "property-change" and item.get("name") in STATES:
                record(property=item["name"], value=item.get("data"))
                if item["name"] == "eof-reached" and item.get("data") is True:
                    return True
                continue
            index = item.get("request_id", 0)
            if not 1 <= index <= len(names):
                continue
            name = names[index - 1]
            if name in STATES and item.get("error") == "success":
                continue
            value = item.get("data")
            if name == "demuxer-cache-state" and isinstance(value, dict):
                value = {k: value.get(k) for k in ("raw-input-rate", "cache-duration", "underrun")}
            record(property=name, value=value, error=item.get("error"))
        record(event="time_limit")
        return not getattr(args, "require_eof", False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    endpoint = parser.add_mutually_exclusive_group(required=True)
    endpoint.add_argument("--pipe", help="Windows local pipe name")
    endpoint.add_argument("--port", type=int, help="Local adb-forward TCP port")
    parser.add_argument("--pid", type=int, help="Expected Windows server process ID")
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument("--require-eof", action="store_true", help="Fail if the trace times out before end of file")
    parser.add_argument("--output", type=Path, required=True, help="New JSONL file")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 7200:
        parser.error("Duration must be between 1 second and 2 hours")
    if args.pipe and (os.name != "nt" or "/" in args.pipe or "\\" in args.pipe):
        parser.error("Expected a local Windows pipe name")
    raise SystemExit(0 if measure(args) else 1)

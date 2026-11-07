"""Read explicitly listed local media; never downloads, transcodes or scans a library."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess


VIDEO_FIELDS = (
    "codec_name", "profile", "pix_fmt", "bits_per_raw_sample", "width", "height",
    "r_frame_rate", "avg_frame_rate", "field_order", "sample_aspect_ratio",
    "color_range", "color_space", "color_transfer", "color_primaries",
)
AUDIO_FIELDS = (
    "codec_name", "profile", "sample_fmt", "sample_rate", "bits_per_raw_sample",
    "bits_per_sample", "channels", "channel_layout",
)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def probe(path, ffprobe, timeout):
    before = path.stat()
    result = subprocess.run(
        [str(ffprobe), "-v", "error", "-show_streams", "-show_format",
         "-show_chapters", "-of", "json", str(path)],
        capture_output=True, timeout=timeout, check=True, encoding="utf-8",
    )
    raw = json.loads(result.stdout)
    digest = sha256(path)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise RuntimeError("Media changed during probing; discard this result")
    groups = []
    for stream in raw.get("streams", []):
        kind = stream.get("codec_type")
        if kind not in ("video", "audio"):
            continue
        fields = VIDEO_FIELDS if kind == "video" else AUDIO_FIELDS
        groups.append({
            "type": kind, "stream_index": stream["index"],
            # Null explicitly means unknown; sample_fmt is storage, not precision.
            "parameters": {key: stream.get(key) for key in fields},
        })
    return {
        "path": str(path), "bytes": before.st_size, "sha256": digest,
        "stream_groups": groups, "ffprobe": raw,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffprobe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("media", nargs="+", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Use a new output path; previous evidence is never overwritten")
    paths = list(dict.fromkeys(p.resolve(strict=True) for p in args.media))
    if any(not p.is_file() for p in paths):
        parser.error("List individual local files, not directories or URLs")
    ffprobe = args.ffprobe.resolve(strict=True)
    version = subprocess.run([str(ffprobe), "-version"], capture_output=True,
                             check=True, encoding="utf-8", timeout=10).stdout.splitlines()[0]
    report = {
        "schema": 1, "utc": datetime.now(timezone.utc).isoformat(),
        "ffprobe_version": version, "ffprobe_sha256": sha256(ffprobe),
        "limitations": "Stream inventory only. No decode, audible output, hardware, "
                        "render precision or performance acceptance implied.",
        "media": [], "errors": [],
    }
    for path in paths:
        try:
            report["media"].append(probe(path, ffprobe, args.timeout))
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
            report["errors"].append({"path": str(path), "error": type(exc).__name__})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print(json.dumps({"probed": len(report["media"]), "errors": len(report["errors"])}))
    return int(bool(report["errors"]))


if __name__ == "__main__":
    raise SystemExit(main())

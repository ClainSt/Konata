"""Bounded, read-only CD2 probe. Called by the opt-in Flutter harness."""
import hashlib
import itertools
import json
import statistics
import sys
import time
import urllib.request
from pathlib import Path


def main():
    config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    video = Path(config["mounted_video"])
    size = video.stat().st_size
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    sources = ["mount", "direct", "before", "after"]
    results = []
    # Balance every source's position in the access order. No caches are cleared.
    orders = list(itertools.permutations(sources))
    for iteration, order in enumerate(orders):
        length = 1048576 if iteration % 2 else 32768
        offset = [0, size // 2, size - 1048576][iteration % 3]
        for label in order:
            row = dict(round=iteration, source=label, offset=offset, length=length)
            start = time.perf_counter()
            if label == "mount":
                with video.open("rb", buffering=0) as stream:
                    stream.seek(offset)
                    headers_at = time.perf_counter()
                    first = stream.read(1)
                    first_at = time.perf_counter()
                    data = first + stream.read(length - 1)
            else:
                headers = {"Range": f"bytes={offset}-{offset+length-1}"}
                if label == "direct":
                    headers["Authorization"] = "Basic YW5vbnltb3VzOg=="
                request = urllib.request.Request(config[label], headers=headers)
                with opener.open(request, timeout=30) as stream:
                    headers_at = time.perf_counter()
                    assert stream.status == 206
                    assert stream.headers["Content-Range"] == f"bytes {offset}-{offset+length-1}/{size}"
                    first = stream.read(1)
                    first_at = time.perf_counter()
                    data = first + stream.read(length - 1)
            ended = time.perf_counter()
            assert len(data) == length
            row.update(headers_ms=(headers_at-start)*1000,
                       first_byte_ms=(first_at-start)*1000,
                       total_ms=(ended-start)*1000,
                       sha256=hashlib.sha256(data).hexdigest())
            results.append(row)
    for offset, length in {(r["offset"], r["length"]) for r in results}:
        assert len({r["sha256"] for r in results if r["offset"] == offset and r["length"] == length}) == 1
    summary = {}
    for label in sources:
        rows = [r for r in results if r["source"] == label]
        summary[label] = {key: round(statistics.median(r[key] for r in rows), 3)
                          for key in ["headers_ms", "first_byte_ms", "total_ms"]}
    output = dict(cache="not cleared; repeated access; NOT cold start", file_bytes=size,
                  samples_match=True, reads=results, medians=summary)
    Path(config["output"]).write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()

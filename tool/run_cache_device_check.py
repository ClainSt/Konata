"""Run the isolated release cache probe; no desktop UI or playback."""
import argparse
import base64
import json
from pathlib import Path
import queue
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        parser.error('Preserve prior evidence; choose a new output file')
    adb = [args.adb, '-s', args.device]
    package = 'com.anime.konata.acceptance'
    subprocess.run(adb + ['shell', 'am', 'force-stop', package], check=True)
    logger = subprocess.Popen(adb + ['logcat', '-T', '1', '-v', 'brief', 'flutter:I', '*:S'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in logger.stdout], daemon=True).start()
    chunks, captured = [], []
    try:
        subprocess.run(adb + ['shell', 'am', 'start', '-n', package + '/com.anime.konata.MainActivity'], check=True)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                continue
            if 'CACHE_' not in line:
                continue
            captured.append(line)
            if 'CACHE_RESULT_PART ' in line:
                chunks.append(line.split('CACHE_RESULT_PART ', 1)[1].rstrip('\r\n'))
            if 'CACHE_SAMPLE ' in line:
                print(line.strip(), flush=True)
            if 'CACHE_PROBE_FAILED' in line:
                raise RuntimeError(line)
            if 'CACHE_PROBE_DONE' in line:
                result = json.loads(base64.b64decode(''.join(chunks)))
                result['deviceSerial'] = args.device
                args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
                print('PROBE_SAVED', str(args.output), flush=True)
                return
        raise TimeoutError('Cache probe did not finish within five minutes')
    finally:
        args.output.with_suffix('.log').write_text(''.join(captured), encoding='utf-8')
        logger.terminate()
        logger.wait(timeout=10)
        subprocess.run(adb + ['shell', 'am', 'force-stop', package], check=True)


if __name__ == '__main__':
    main()

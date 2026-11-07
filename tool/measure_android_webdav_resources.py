"""Bounded Android resource observer; optionally drives one HOME/return.

HOME/return is restricted to the independent Profile resource experiment.
The Release package is allowed only with --observe-only.
Never changes power policy, clears caches, locks the screen, or forwards media.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--component', required=True)
    parser.add_argument('--observe-only', action='store_true',
                        help='Read resources without HOME/return or any app control')
    parser.add_argument('--stop-file', type=Path)
    parser.add_argument('--seconds', type=int, default=1800)
    args = parser.parse_args()
    package = args.component.split('/')[0]
    if package != 'com.anime.konata.profile' and not (
            args.observe_only and package == 'com.anime.konata'):
        raise ValueError('Use Profile, or Release with --observe-only')
    if not 1 <= args.seconds <= 7200:
        raise ValueError('Expected a bounded experiment of 1-7200 seconds')
    cd2 = 'com.clouddrive2.CloudDrive2'

    def adb(*command):
        result = subprocess.run([args.adb, '-s', args.serial, *command],
                                capture_output=True, text=True, encoding='utf-8',
                                errors='replace', timeout=25)
        if result.returncode:
            raise RuntimeError('ADB command failed: ' + command[0])
        return result.stdout.strip()

    def memory(target):
        pid = adb('shell', 'pidof', target) if target == cd2 else ''
        if target != cd2:
            found = subprocess.run([args.adb, '-s', args.serial, 'shell', 'pidof', target],
                                   capture_output=True, text=True, timeout=10)
            pid = found.stdout.strip()
        if not pid:
            return {'present': False}
        data = adb('shell', 'dumpsys', 'meminfo', pid)
        values = {'present': True, 'pid': pid}
        for name, expression in {
            'pss_kib': r'TOTAL PSS:\s*(\d+)',
            'rss_kib': r'TOTAL RSS:\s*(\d+)',
            'swap_pss_kib': r'TOTAL SWAP PSS:\s*(\d+)',
            'native_heap_private_kib': r'Native Heap:\s*(\d+)',
            'graphics_private_kib': r'Graphics:\s*(\d+)',
        }.items():
            match = re.search(expression, data)
            values[name] = int(match[1]) if match else None
        return values

    args.output.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    next_sample = 0.0
    last_marker = None
    phase, round_number = 'waiting', 0
    background_start = None
    returned = False
    with args.output.open('x', encoding='utf-8') as output:
        def emit(value):
            value['elapsed_s'] = round(time.monotonic() - start, 3)
            value['time'] = datetime.datetime.now().astimezone().isoformat()
            output.write(json.dumps(value, ensure_ascii=False) + '\n')
            output.flush()

        while time.monotonic() - start < args.seconds:
            if args.stop_file and args.stop_file.exists():
                emit({'event': 'observer_stopped'})
                return
            if args.log.exists():
                content = args.log.read_text(encoding='utf-8-sig', errors='replace')
                markers = re.findall(r'SOAK_MARK (\{[^\n\r]+\})', content)
                if markers and markers[-1] != last_marker:
                    last_marker = markers[-1]
                    marker = json.loads(last_marker)
                    phase, round_number = marker['phase'], marker['round']
                    emit({'event': 'phase', **marker})
                    print(f'Phase {phase}, round {round_number}', flush=True)
                    next_sample = 0
                if 'All tests passed.' in content or 'Failure Details:' in content:
                    emit({'event': 'driver_finished', 'passed': 'All tests passed.' in content})
                    return
            now = time.monotonic()
            if not args.observe_only and phase == 'background_ready' and background_start is None:
                adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                background_start = time.monotonic()
                emit({'event': 'home_sent', 'seconds_requested': 600})
                print('Background interval started (600 seconds)', flush=True)
            if background_start is not None and not returned and now - background_start >= 600:
                # Sample freezer before the HTTP probe or activity launch.
                freezer = adb('shell', 'dumpsys', 'greezer')
                frozen = re.search(r'Frozen processes:\s*\[([^\]]*)\]', freezer)
                pid = adb('shell', 'pidof', cd2)
                freeze_state = pid in re.findall(r'\d+', frozen[1]) if frozen else None
                try:
                    probe = adb('shell', 'curl', '-sS', '--max-time', '8', '-o', '/dev/null',
                                '-w', 'status=%{http_code},headers=%{time_starttransfer}',
                                'http://127.0.0.1:29798/')
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    probe = type(error).__name__
                emit({'event': 'background_end', 'cd2_vendor_frozen': freeze_state,
                      'cd2_probe': probe, 'background_s': time.monotonic() - background_start})
                adb('shell', 'am', 'start', '-n', args.component)
                returned = True
                print('Returned to Profile experiment', flush=True)
            if now >= next_sample:
                app = memory(package)
                cloud = memory(cd2)
                freezer = adb('shell', 'dumpsys', 'greezer')
                frozen = re.search(r'Frozen processes:\s*\[([^\]]*)\]', freezer)
                frozen_pids = re.findall(r'\d+', frozen[1]) if frozen else None
                battery = adb('shell', 'dumpsys', 'battery')
                temp = re.search(r'^\s*temperature:\s*(\d+)', battery, re.M)
                wifi = adb('shell', 'cmd', 'wifi', 'status')
                frequency = re.search(r'Frequency:\s*(\d+)', wifi)
                rssi = re.search(r'RSSI:\s*(-?\d+)', wifi)
                emit({'event': 'sample', 'phase': phase, 'round': round_number,
                      'app': app, 'cd2': cloud,
                      'app_vendor_frozen': app.get('pid') in frozen_pids if frozen_pids is not None else None,
                      'cd2_vendor_frozen': cloud.get('pid') in frozen_pids if frozen_pids is not None else None,
                      'battery_temperature_c': int(temp[1]) / 10 if temp else None,
                      'ac_powered': 'AC powered: true' in battery,
                      'wifi_frequency_mhz': int(frequency[1]) if frequency else None,
                      'wifi_rssi_dbm': int(rssi[1]) if rssi else None})
                next_sample = time.monotonic() + 25
            if phase == 'complete':
                emit({'event': 'experiment_complete'})
                return
            time.sleep(1)
        if args.observe_only:
            emit({'event': 'observation_time_limit'})
            return
        raise TimeoutError('Experiment did not complete within its time limit')


if __name__ == '__main__':
    main()

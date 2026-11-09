"""Run bounded real-file WatchPage checks; Android install prompts are handled.

Manifest: [{"path": absolute_file, "sha256": hash, "depth": 10}].
Android --stage-url must be an already configured loopback fixture server.
This runner never installs over the public Android application.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def confirm_install(adb, device):
    command = [adb, '-s', device, 'shell']
    dumped = subprocess.run(command + ['uiautomator', 'dump', '/data/local/tmp/konata-install-ui.xml'],
                   capture_output=True, check=True, timeout=8)
    if b'ERROR' in dumped.stdout + dumped.stderr:
        raise subprocess.CalledProcessError(1, 'uiautomator dump')
    xml = subprocess.check_output(command + ['cat', '/data/local/tmp/konata-install-ui.xml'], timeout=5)
    installers = {'com.miui.packageinstaller', 'com.miui.securitycenter',
                  'com.android.packageinstaller', 'com.google.android.packageinstaller'}
    nodes = [n for n in ET.fromstring(xml).iter('node') if n.get('package') in installers]
    if not any('konata' in n.get('text', '').lower() for n in nodes):
        return
    for node in nodes:
        if node.get('enabled') != 'true' or not re.fullmatch(
                r'继续安装|继续|安装|允许本次安装|允许', node.get('text', '')):
            continue
        bounds = [int(v) for v in re.findall(r'\d+', node.get('bounds', ''))]
        if len(bounds) == 4:
            subprocess.run(command + ['input', 'tap', str((bounds[0] + bounds[2]) // 2),
                                      str((bounds[1] + bounds[3]) // 2)], check=True, timeout=5)
            print('INSTALL_CONFIRMED', flush=True)
            return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--adb')
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--stage-url', default='')
    parser.add_argument('--mode', default='automatic', choices=['automatic', 'software', 'hardwarePreferred'])
    parser.add_argument('--seconds', type=int, default=20)
    parser.add_argument('--resume-seconds', type=int, default=0)
    parser.add_argument('--all-audio', action='store_true')
    parser.add_argument('--render-api', action='store_true')
    parser.add_argument('--window-interactions', action='store_true')
    args = parser.parse_args()
    android = args.device != 'windows'
    if android and (not args.adb or not args.stage_url.startswith('http://127.0.0.1:')):
        parser.error('Android requires --adb and a loopback --stage-url.')
    if not 1 <= args.seconds <= 3600:
        parser.error('--seconds must be 1..3600')
    if not 0 <= args.resume_seconds <= 3600:
        parser.error('--resume-seconds must be 0..3600')
    if args.report.exists():
        parser.error('Choose a new report path to preserve previous evidence.')
    root = Path(__file__).resolve().parent.parent
    fixtures = json.loads(args.manifest.read_text(encoding='utf-8-sig'))
    env = dict(os.environ, CCPLAYER_ISOLATED_VALIDATION='1')
    results = []
    for i, fixture in enumerate(fixtures):
        media = Path(fixture['path'])
        with media.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest.lower() != fixture['sha256'].lower():
            raise ValueError('Fixture SHA-256 mismatch')
        defines = root / '.dart_tool' / f'bdrip-{args.device}-{i}.json'
        defines.write_text(json.dumps({
            'BASELINE_VIDEO': str(media) if not android else media.name,
            'BASELINE_STAGE_URL': f'{args.stage_url.rstrip("/")}/{media.name}' if android else '',
            'BASELINE_DECODE_MODE': args.mode, 'BASELINE_SAMPLE_SECONDS': args.seconds,
            'BASELINE_RESUME_SECONDS': args.resume_seconds,
            'BASELINE_VOLUME': 20, 'BASELINE_ALL_AUDIO': args.all_audio,
            'CCPLAYER_D3D11_RENDER_API': args.render_api,
            'BASELINE_WINDOWS_SCREEN': args.window_interactions,
            'BASELINE_REQUIRE_PRECISION': True, 'BASELINE_EXPECT_DECODED_DEPTH': fixture['depth'],
        }), encoding='utf-8')
        log = root / 'build' / f'{args.report.stem}-{i}.log'
        with log.open('w', encoding='utf-8') as output:
            process = subprocess.Popen([args.flutter, 'test', '--no-pub', '-d', args.device,
                'integration_test/local_mpv_baseline_test.dart', f'--dart-define-from-file={defines}',
                '--reporter', 'expanded'], cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + args.seconds + 300
            while process.poll() is None:
                if time.monotonic() > deadline:
                    process.kill()
                    raise TimeoutError('Bounded device validation timed out')
                if android:
                    current = log.read_text(encoding='utf-8', errors='replace')
                    if 'Installing ' in current and 'VideoOutput.' not in current:
                        try:
                            confirm_install(args.adb, args.device)
                        except (subprocess.SubprocessError, ET.ParseError):
                            pass
                time.sleep(1)
        lines = log.read_text(encoding='utf-8', errors='replace').splitlines()
        def read_marker(marker):
            return next((json.loads(line.split(marker, 1)[1]) for line in lines if marker in line), None)
        results.append({'file': media.name, 'sha256': digest, 'mode': args.mode,
                        'resume_seconds': args.resume_seconds,
                        'exit_code': process.returncode,
                        'stats': read_marker('MPV_LOCAL_BASELINE '),
                        'audio_tracks': read_marker('MPV_AUDIO_BASELINE ')})
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({'sample': i, 'exit_code': process.returncode}), flush=True)
        if process.returncode:
            raise SystemExit(process.returncode)


if __name__ == '__main__':
    main()

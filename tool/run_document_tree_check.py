"""Run the isolated SAF regression with the known Download validation folder."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

from run_bdrip_device import confirm_install


def select_folder(adb, device):
    base = [adb, '-s', device, 'shell']
    subprocess.run(base + ['uiautomator', 'dump', '/data/local/tmp/konata-saf-picker.xml'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
    xml = subprocess.check_output(base + ['cat', '/data/local/tmp/konata-saf-picker.xml'], timeout=5)
    nodes = [n for n in ET.fromstring(xml).iter('node')
             if n.get('package') in {'com.google.android.documentsui', 'com.android.documentsui'}]
    if not nodes:
        return
    texts = [n.get('text', '') for n in nodes]
    target = 'KonataValidation20261107'
    confirmation = any('Konata' in t and target in t and '允许' in t for t in texts)
    # The toolbar title proves we are inside the intended folder before granting.
    inside = any(n.get('text') == target and 'toolbar' in n.get('resource-id', '') for n in nodes)
    # A breadcrumb plus the folder heading is also exposed by DocumentsUI versions.
    inside = inside or any(t == f'{target} 中的文件' for t in texts)
    wanted = '允许' if confirmation else '使用此文件夹' if inside else target if target in texts else 'Download'
    matches = [n for n in nodes if n.get('text') == wanted and n.get('enabled') == 'true']
    if not matches:
        return
    bounds = [int(v) for v in re.findall(r'\d+', matches[-1].get('bounds', ''))]
    if len(bounds) != 4:
        return
    subprocess.run(base + ['input', 'tap', str((bounds[0]+bounds[2])//2),
                           str((bounds[1]+bounds[3])//2)], check=True, timeout=5)
    print('SAF_UI', wanted, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--flutter', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--test', default='local_document_tree_test.dart',
                        choices=['local_document_tree_test.dart', 'android_surface_precision_test.dart'])
    parser.add_argument('--output-format', default='rgb10_a2', choices=['rgb10_a2', 'rgba8'])
    parser.add_argument('--hwdec', default='no', choices=['no', 'mediacodec', 'mediacodec-copy'])
    parser.add_argument('--stage-url', default='http://127.0.0.1:18768/gradient10-long.mkv')
    args = parser.parse_args()
    if not args.stage_url.startswith('http://127.0.0.1:'):
        parser.error('Fixture staging must use the local loopback server')
    env = dict(os.environ, CCPLAYER_ISOLATED_VALIDATION='1')
    vm_port = None
    captured_surface = False
    with args.log.open('x', encoding='utf8') as output:
        # Forward this test's host DDS explicitly so the device can request GC.
        process = subprocess.Popen([args.flutter, 'test', '--no-pub', '-d', args.device,
            'integration_test/' + args.test, '--dart-define=SURFACE_OUTPUT_FORMAT=' + args.output_format,
            '--dart-define=SURFACE_HWDEC=' + args.hwdec,
            '--dart-define=SURFACE_STAGE_URL=' + args.stage_url,
            '--reporter', 'expanded'],
            env=env, stdout=output, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 420
        while process.poll() is None and time.monotonic() < deadline:
            content = args.log.read_text(encoding='utf8', errors='replace')
            marker = re.search(r'SAF_VM_PORT (\d+)', content)
            try:
                if 'ANDROID_SURFACE_PRECISION ' in content and not captured_surface:
                    compositor = subprocess.check_output([args.adb, '-s', args.device, 'shell',
                        'dumpsys', 'SurfaceFlinger'], text=True, encoding='utf8', errors='replace', timeout=10)
                    lines = [line for line in compositor.splitlines()
                             if 'name:' in line and 'com.anime.konata.validation' in line]
                    args.log.with_suffix('.surface.txt').write_text('\n'.join(lines), encoding='utf8')
                    captured_surface = True
                if marker:
                    port = int(marker[1])
                    if not 1 <= port <= 65535:
                        raise ValueError('Invalid VM loopback port')
                    if vm_port is None:
                        subprocess.run([args.adb, '-s', args.device, 'reverse', f'tcp:{port}', f'tcp:{port}'], check=True)
                        vm_port = port
                elif 'SAF_PICKER_READY' in content:
                    select_folder(args.adb, args.device)
                elif 'Installing ' in content and 'media_kit: NativeReferenceHolder' not in content:
                    confirm_install(args.adb, args.device)
            except (subprocess.SubprocessError, ET.ParseError):
                pass
            time.sleep(1)
        if process.poll() is None:
            process.kill()
            if vm_port:
                subprocess.run([args.adb, '-s', args.device, 'reverse', '--remove', f'tcp:{vm_port}'], check=True)
            raise TimeoutError('SAF regression exceeded its limit')
        if vm_port:
            subprocess.run([args.adb, '-s', args.device, 'reverse', '--remove', f'tcp:{vm_port}'], check=True)
        print('SAF_TEST_EXIT', process.returncode, flush=True)
        raise SystemExit(process.returncode)


if __name__ == '__main__':
    main()

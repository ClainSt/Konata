"""Compare paired pre-swap RGB10 and PixelCopy F16 at identical image coordinates."""
import argparse
import json
from pathlib import Path
import statistics
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--require-pass', action='store_true',
                        help='Exit nonzero unless both original numeric thresholds pass.')
    parser.add_argument('--fixture', type=Path, default=Path('.dart_tool/hdr-pattern.json'))
    parser.add_argument('--evidence', type=Path, default=Path('docs/verification/hdr-output-20261109'))
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    measurement = json.loads((args.evidence / f'{args.tag}-measure.json').read_text())
    fallback_warnings = [line for line in measurement.get('logs', [])
                         if 'Enabling dumb mode' in line or 'failed to initialize' in line]
    results = []
    for frame in [0, 2]:
        stem = args.evidence / f'{args.tag}-pattern-{frame}'
        data = json.loads(stem.with_suffix('.json').read_text())
        target = json.loads(data['mpv']['video-target-params'])
        surface = data['surface']
        header, direct = Path(str(stem)+'-egl.bin').read_bytes().split(b'\n', 1)
        egl = json.loads(header)
        assert all(egl[k] == 0 for k in ['priorError', 'setupError', 'readError']), egl
        assert egl['bits'] == [10, 10, 10, 2] and egl['pq'], egl
        assert egl['rows'] == 5 and egl['sequence'] <= 64, egl
        assert egl['format'] == 0x1908 and egl['type'] == 0x8368, egl
        assert float(data['mpv']['time-pos']) == frame
        assert egl['width'] == surface['width'] and egl['height'] == surface['height']
        assert len(direct) == egl['width'] * 5 * 4
        assert target['gamma'] == 'pq' and target['primaries'] == 'bt.2020'
        assert surface['readback'] == 'RGBA_F16'
        copied = stem.with_suffix('.raw').read_bytes()
        left = (surface['width'] - target['w']) / 2
        top = (surface['height'] - target['h']) / 2
        y = round(top + target['h'] / 2 - .5)
        observations = []
        for sample in fixture['samples'][frame]:
            x = round(left + sample['x'] * target['w'] / fixture['width'] - .5)
            packed = [struct.unpack_from('<I', direct, (row * egl['width'] + x)*4)[0]
                      for row in range(5)]
            rgb = [statistics.median((pixel >> (c*10)) & 1023 for pixel in packed)/1023
                   for c in range(3)]
            f16 = [struct.unpack_from('<4e', copied, row*surface['rowBytes']+x*8)[:3]
                   for row in range(y-2, y+3)]
            pc = [statistics.median(row[c] for row in f16) for c in range(3)]
            observations.append({'sourceX': sample['x'], 'surfaceX': x,
                'expected': sample['rgb'], 'egl': rgb, 'pixelCopy': pc,
                'eglErrorCodes': [abs(a-b)*1023 for a,b in zip(rgb, sample['rgb'])],
                'pixelCopyErrorCodes': [abs(a-b)*1023 for a,b in zip(pc, sample['rgb'])],
                'copyDeltaCodes': [(a-b)*1023 for a,b in zip(pc, rgb)]})
        def errors(key):
            vals = [abs(v) for sample in observations for v in sample[key]]
            return {'max': max(vals), 'mean': statistics.mean(vals)}
        distinct = len({round(s['egl'][1]*1023) for s in observations})
        passed = errors('eglErrorCodes')['max'] <= fixture['flatInteriorTolerance10bitCodes']
        if frame == 0:
            passed &= distinct >= fixture['rampMinimumDistinctLevels']
        results.append({'frame': frame, 'timePos': data['mpv']['time-pos'], 'eglHeader': egl,
            'directEglError': errors('eglErrorCodes'), 'pixelCopyError': errors('pixelCopyErrorCodes'),
            'pixelCopyVsEgl': errors('copyDeltaCodes'), 'directEglDistinctGreen': distinct,
            'directEglPassed': passed and not fallback_warnings, 'observations': observations})
    report = {'fixtureSha256': fixture['sha256'], 'thresholdCodes': fixture['flatInteriorTolerance10bitCodes'],
              'intendedRenderPathValid': not fallback_warnings,
              'fallbackWarnings': fallback_warnings,
              'scope': 'Pre-swap window framebuffer vs PixelCopy; not physical display output',
              'frames': results}
    (args.evidence / f'{args.tag}-egl-result.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({**report, 'frames': [{k:v for k,v in f.items() if k != 'observations'} for f in results]}))
    if args.require_pass and not all(f['directEglPassed'] for f in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()

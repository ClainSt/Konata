"""Recompute Windows DV8.1 SDR acceptance from actual R10G10B10A2 captures.

Keeps the failed pre-fix reports intact. No physical-display fidelity claim.
"""
import array
import hashlib
import json
from pathlib import Path

ROOT = Path('docs/verification/hdr-output-20261109')


def capture(stem, decoder=None, expected_pts=0):
    data = json.loads((ROOT / (stem + '.json')).read_text())
    surface, mpv = data['surface'], data['mpv']
    assert surface['format'] == 'R10G10B10A2_UNORM'
    assert surface['outputColorSpace'] == 'sdr'
    assert float(mpv['time-pos']) == expected_pts
    assert mpv['dither'] == 'no' and mpv['hdr-compute-peak'] == 'no'
    assert not any('KONATA_' in line for line in data['logs']), 'Diagnostic native library'
    if decoder:
        assert mpv['hwdec-current'] == decoder
    raw = (ROOT / (stem + '.raw')).read_bytes()
    assert len(raw) == surface['width'] * surface['height'] * 4
    values = array.array('I')
    values.frombytes(raw)
    return (surface['width'], surface['height']), values, hashlib.sha256(raw).hexdigest()


def delta(a, b):
    assert len(a) == len(b)
    return max(abs(((x >> s) & 1023) - ((y >> s) & 1023))
               for x, y in zip(a, b) for s in (0, 10, 20))


def main():
    results = []
    for branch, decoder in [('hw', 'd3d11va'), ('sw', 'no')]:
        tag = f'windows-dv81-final-{branch}-v1'
        size, reference, _ = capture(tag + '-dv81sceneref-metadata-on', decoder)
        assert len(set(reference)) > 32, 'Single-color fixture is not quality evidence'
        paths = sorted(ROOT.glob(tag + '-*.raw'))
        assert len(paths) == 16
        for path in paths:
            actual_size, values, sha = capture(path.stem, decoder)
            assert actual_size == size
            difference = delta(values, reference)
            results.append({'case': path.stem, 'maxRgb10Difference': difference,
                            'sha256': sha, 'passed': difference <= 1})
    tag = 'windows-dv81-affected-v1'
    for kind, reference_kind in [('dv7', 'dv7ref'), ('dv84', 'dv84ref')]:
        size, reference, _ = capture(f'{tag}-{reference_kind}-metadata-on', 'd3d11va')
        for mode in ['on', 'off']:
            stem = f'{tag}-{kind}-metadata-{mode}'
            actual_size, values, sha = capture(stem, 'd3d11va')
            assert actual_size == size
            difference = delta(values, reference)
            results.append({'case': stem, 'maxRgb10Difference': difference,
                            'sha256': sha, 'passed': difference <= 1})
    # SDR is directly affected by the shared pixel-shader compiler flag.
    size, before, _ = capture('windows-dv81-cost-before-v1-sdr-metadata-on')
    for mode in ['on', 'off']:
        stem = f'{tag}-sdr-metadata-{mode}'
        actual_size, after, sha = capture(stem)
        assert actual_size == size
        difference = delta(before, after)
        results.append({'case': stem, 'maxRgb10Difference': difference,
                        'sha256': sha, 'passed': difference <= 1})
    report = {'scope': 'Windows SDR digital render buffers, selected first frames only',
              'thresholdCodes': 1, 'results': results}
    (ROOT / 'dv81-windows-fixed-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'cases': len(results), 'maxDifference': max(r['maxRgb10Difference'] for r in results),
                      'passed': all(r['passed'] for r in results)}))
    assert all(r['passed'] for r in results), 'See dv81-windows-fixed-results.json'


if __name__ == '__main__':
    main()

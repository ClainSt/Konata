"""Check DV8.4 HLG fallback against the same RPU-stripped base layer.
No PixelCopy, physical display or full Dolby Vision fidelity claim.
"""
import array
import json
from pathlib import Path

ROOT = Path('docs/verification/hdr-output-20261109')

def capture(stem, mobile):
    data = json.loads((ROOT / (stem + '.json')).read_text())
    assert float(data['mpv']['time-pos']) == 0
    if mobile:
        header, raw = (ROOT / (stem + '-egl.bin')).read_bytes().split(b'\n', 1)
        surface = json.loads(header)
        assert surface['bits'] == [10, 10, 10, 2]
        assert all(surface[k] == 0 for k in ['priorError', 'setupError', 'readError'])
        assert len(raw) == surface['width'] * 5 * 4
    else:
        surface = data['surface']
        assert surface['format'] == 'R10G10B10A2_UNORM'
        raw = (ROOT / (stem + '.raw')).read_bytes()
        assert len(raw) == surface['width'] * surface['height'] * 4
    values = array.array('I'); values.frombytes(raw)
    return data, surface, values

def delta(a, b):
    assert len(a) == len(b)
    return max(abs(((x >> s) & 1023) - ((y >> s) & 1023))
               for x, y in zip(a, b) for s in (0, 10, 20))

def main():
    results = []
    for device in ['phone', 'tablet', 'windows']:
        mobile = device != 'windows'
        prefix = f'{device}-' if mobile else 'windows-dv84-fixed-v2-'
        def stem(kind, mode):
            if device == 'phone' and kind == 'dv7':
                return f'phone-dv7-fixed-v2-metadata-{mode}'
            return (f'{prefix}{kind}-fixed-v1-metadata-{mode}' if mobile else
                    f'{prefix}{kind}-metadata-{mode}')
        _, reference_surface, reference = capture(stem('dv84ref', 'on'), mobile)
        for mode in ['on', 'off']:
            data, surface, values = capture(stem('dv84', mode), mobile)
            assert surface['width'] == reference_surface['width']
            assert (not surface['pq'] and surface['dataspace'] == 0) if mobile else surface['outputColorSpace'] == 'sdr'
            difference = delta(values, reference)
            assert difference <= 1, (device, mode, difference)
            if mode == 'off':
                params = json.loads(data['mpv']['video-out-params'])
                assert params['gamma'] == 'hlg' and params['light'] == 'hlg'
            results.append({'device': device, 'case': 'dv84-' + mode, 'maxRgb10Difference': difference, 'passed': True})
        for mode in ['on', 'off']:
            _, surface, values = capture(stem('dv7', mode), mobile)
            old = (f'{device}-dv7-metadata-v2-metadata-{mode}' if mobile else
                   f'windows-dv7-v3-dv7-metadata-{mode}')
            _, old_surface, old_values = capture(old, mobile)
            assert surface['width'] == old_surface['width']
            if mobile: assert surface['pq'] and old_surface['pq']
            difference = delta(values, old_values)
            assert difference <= 1, (device, 'dv7', mode, difference)
            results.append({'device': device, 'case': 'dv7-' + mode, 'maxRgb10Difference': difference, 'passed': True})
    report = {'scope': 'DV8.4 HLG base-layer fallback and affected DV7 boundary only', 'thresholdCodes': 1, 'results': results}
    (ROOT / 'dv84-fixed-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(results))

if __name__ == '__main__':
    main()

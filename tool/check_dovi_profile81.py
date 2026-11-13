"""Compare Profile 8.1 output with its bit-identical RPU-stripped base layer."""
import array
import json
import sys
from pathlib import Path

root = Path('docs/verification/hdr-output-20261109')
scene = '--scene' in sys.argv
kind = 'dv81scene' if scene else 'dv81'
reference_kind = kind + 'ref'


def capture(stem, mobile):
    data = json.loads((root / (stem + '.json')).read_text())
    assert float(data['mpv']['time-pos']) == 0
    if mobile:
        header, raw = (root / (stem + '-egl.bin')).read_bytes().split(b'\n', 1)
        surface = json.loads(header)
        assert surface['bits'] == [10, 10, 10, 2]
        assert all(surface[k] == 0 for k in ['priorError', 'setupError', 'readError'])
        assert surface['pq'] and surface['dataspace'] == 0x09c60000
        assert len(raw) == surface['width'] * 5 * 4
    else:
        surface = data['surface']
        assert surface['outputColorSpace'] == 'sdr'
        assert surface['format'] == 'R10G10B10A2_UNORM'
        raw = (root / (stem + '.raw')).read_bytes()
        assert len(raw) == surface['width'] * surface['height'] * 4
    pixels = array.array('I')
    pixels.frombytes(raw)
    return data, surface, pixels


results = []
for device in ['phone', 'tablet', 'windows']:
    mobile = device != 'windows'

    def stem(name, mode):
        if mobile:
            return f'{device}-{name}-v1-metadata-{mode}'
        return f'windows-{kind}-v1-{name}-metadata-{mode}'

    _, reference_surface, reference = capture(stem(reference_kind, 'on'), mobile)
    distinct = len(set(value & 0x3fffffff for value in reference))
    if scene:
        assert distinct > 32, (device, 'insufficient scene variation', distinct)
    for mode in ['on', 'off']:
        data, surface, pixels = capture(stem(kind, mode), mobile)
        assert len(pixels) == len(reference)
        assert surface['width'] == reference_surface['width']
        difference = max(abs(((x >> shift) & 1023) - ((y >> shift) & 1023))
                         for x, y in zip(pixels, reference) for shift in (0, 10, 20))
        results.append({'device': device, 'mode': mode,
                        'maxRgb10Difference': difference,
                        'distinctReferenceRgb10': distinct,
                        'postFilter': json.loads(data['mpv']['video-out-params']),
                        'surface': surface, 'passed': difference <= 1})
report = {'scope': 'Specified Profile 8.1 first frame; no full Dolby Vision or physical fidelity claim',
          'thresholdCodes': 1, 'results': results}
(root / (kind + '-results.json')).write_text(json.dumps(report, indent=2) + '\n')
print([(x['device'], x['mode'], x['maxRgb10Difference']) for x in results])
assert all(x['passed'] for x in results), 'Base-layer fidelity difference exceeds threshold'

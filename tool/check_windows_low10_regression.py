"""Check affected D3D11 low-aligned 10-bit paths against independent references."""
import json
from check_dovi_windows_sdr import ROOT, capture, delta


def main():
    tag = 'windows-cross-affected-v1'
    results = []
    for kind, reference in [
        ('dv81scene', f'{tag}-dv81sceneref-metadata-on'),
        ('dv81sceneref', 'windows-dv81-final-hw-v1-dv81sceneref-metadata-on'),
        ('dv84', f'{tag}-dv84ref-metadata-on'),
        ('dv84ref', 'windows-dv81-affected-v1-dv84ref-metadata-on'),
        ('sdr', 'windows-dv81-affected-v1-sdr-metadata-on'),
        ('hi10p', f'{tag}-hi10pref-metadata-on'),
    ]:
        expected_size, expected, _ = capture(reference)
        assert len(set(expected)) > 32
        for mode in ['on', 'off']:
            actual_tag = 'windows-cross-dovi-final-v1' if kind in ['dv81scene', 'dv84'] else tag
            stem = f'{actual_tag}-{kind}-metadata-{mode}'
            size, actual, sha = capture(stem, 'no')
            assert size == expected_size
            data = json.loads((ROOT / f'{stem}.json').read_text())
            output = json.loads(data['mpv']['video-out-params'])
            assert output['pixelformat'] == 'p010', output
            difference = delta(actual, expected)
            results.append({'case': stem, 'reference': reference, 'sha256': sha,
                            'maxRgb10Difference': difference, 'passed': difference <= 1})
    for mode in ['on', 'off']:
        data = json.loads((ROOT / f'{tag}-hi10pref-metadata-{mode}.json').read_text())
        assert json.loads(data['mpv']['video-out-params'])['pixelformat'] == 'yuv420p16'
    report = {'scope': 'Selected digital SDR buffers; not full episodes or physical display',
              'thresholdCodes': 1, 'results': results}
    (ROOT / 'cross-final-affected-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'cases': len(results), 'maxDifference': max(r['maxRgb10Difference'] for r in results),
                      'passed': all(r['passed'] for r in results)}))
    assert all(r['passed'] for r in results)


if __name__ == '__main__':
    main()

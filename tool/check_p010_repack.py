"""Check only the Windows software paths affected by the P010 repack optimization."""
import json
from check_dovi_windows_sdr import ROOT, capture, delta


def main():
    cases = []
    for index, pts in enumerate([0, 0.5, 1]):
        cases.append((f'windows-p010-final-dv81-v1-sw-{index}',
                      f'windows-cross-final-v1-hw-{index}', pts))
    for kind, reference_tag in [('dv84', 'windows-cross-dovi-final-v1'),
                                ('sdr', 'windows-cross-affected-v1'),
                                ('hi10p', 'windows-cross-affected-v1')]:
        for mode in ['on', 'off']:
            cases.append((f'windows-p010-final-affected-v1-{kind}-metadata-{mode}',
                          f'{reference_tag}-{kind}-metadata-{mode}', 0))
    for boundary in ['forced-zimg', 'resize']:
        cases.append((f'windows-p010-boundary-final-v1-{boundary}',
                      f'windows-p010-boundary-before-v1-{boundary}', 0))
    results = []
    for actual, reference, pts in cases:
        size, values, sha = capture(actual, 'no', expected_pts=pts)
        expected_size, expected, _ = capture(reference, expected_pts=pts)
        assert size == expected_size and len(set(expected)) > 32
        state = json.loads((ROOT / f'{actual}.json').read_text())['mpv']
        assert json.loads(state['video-out-params'])['pixelformat'] == 'p010'
        assert state['scale'] == 'bilinear' and state['fbo-format'] == 'auto'
        error = delta(values, expected)
        results.append({'actual': actual, 'reference': reference, 'pts': pts,
                        'sha256': sha, 'maxRgb10Difference': error, 'passed': error <= 1})
    report = {'scope': 'Selected digital SDR render buffers; physical HDR remains pending',
              'thresholdCodes': 1, 'results': results}
    (ROOT / 'p010-repack-regression.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'cases': len(results), 'maxDifference': max(r['maxRgb10Difference'] for r in results),
                      'passed': all(r['passed'] for r in results)}))
    assert all(r['passed'] for r in results)


if __name__ == '__main__':
    main()

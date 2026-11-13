"""Compare captured flat PQ interiors with the pre-registered source math."""
import argparse
import json
from pathlib import Path
import statistics
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--frames', nargs='+', type=int, default=[0, 1, 2])
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    results = []
    for frame in args.frames:
        path = args.evidence / f'{args.tag}-pattern-{frame}.json'
        data = json.loads(path.read_text())
        surface, mpv = data['surface'], data['mpv']
        target = json.loads(mpv['video-target-params'])
        if target['gamma'] != 'pq' or target['primaries'] != 'bt.2020':
            raise ValueError('Capture is not native BT.2020/PQ')
        raw = path.with_suffix('.raw').read_bytes()
        width, height = target['w'], target['h']
        left = (surface['width'] - width) / 2
        top = (surface['height'] - height) / 2
        y = round(top + height / 2 - .5)
        observations = []
        for sample in fixture['samples'][frame]:
            x = round(left + sample['x'] * width / fixture['width'] - .5)
            if surface['readback'] == 'RGBA_1010102':
                pixels = [struct.unpack_from('<I', raw, yy*surface['rowBytes'] + x*4)[0]
                          for yy in range(y - 2, y + 3)]
                values = [[((pixel >> (c * 10)) & 1023) / 1023 for c in range(3)]
                          for pixel in pixels]
            else:
                values = [struct.unpack_from('<4e', raw, yy*surface['rowBytes'] + x*8)[:3]
                          for yy in range(y - 2, y + 3)]
            actual = [statistics.median(row[c] for row in values) for c in range(3)]
            errors = [abs(a-b)*1023 for a,b in zip(actual, sample['rgb'])]
            observations.append({'sourceX': sample['x'], 'actual': actual,
                                 'expected': sample['rgb'], 'errors10bit': errors})
        errors = [error for row in observations for error in row['errors10bit']]
        distinct = len({row['actual'][1] for row in observations})
        passed = max(errors) <= fixture['flatInteriorTolerance10bitCodes']
        if frame == 0:
            passed &= distinct >= fixture['rampMinimumDistinctLevels']
        results.append({'frame': frame, 'timePos': mpv['time-pos'],
                        'target': target, 'maximumError10bit': max(errors),
                        'meanError10bit': statistics.mean(errors),
                        'distinctGreenLevels': distinct, 'passed': passed,
                        'observations': observations})
    report = {'fixtureSha256': fixture['sha256'],
              'thresholdRegisteredBeforeCapture': fixture['flatInteriorTolerance10bitCodes'],
              'scope': 'Digital source-to-PQ-buffer check; no physical display measurements',
              'passed': all(row['passed'] for row in results), 'frames': results}
    (args.evidence / (args.tag+'-pattern-result.json')).write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({**{k:v for k,v in report.items() if k != 'frames'},
                      'frames': [{k:v for k,v in row.items() if k not in ('target','observations')} for row in results]}))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()

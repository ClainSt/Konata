"""Check new HLG flat interiors against the predeclared CPU mapping reference."""
import argparse
import json
from pathlib import Path
import statistics
import struct


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tag', required=True)
    p.add_argument('--fixture', type=Path, default=Path('.dart_tool/hlg-pattern.json'))
    p.add_argument('--evidence', type=Path, default=Path('docs/verification/hdr-output-20261109'))
    a = p.parse_args()
    fixture = json.loads(a.fixture.read_text())
    results = []
    for frame in fixture['pts']:
        stem = a.evidence / f'{a.tag}-pattern-{frame}'
        data = json.loads(stem.with_suffix('.json').read_text())
        source = json.loads(data['mpv']['video-params'])
        assert source['gamma'] == 'hlg' and source['primaries'] == 'bt.2020'
        assert source['max-luma'] == 1000 and source['light'] == 'hlg'
        assert abs(float(data['mpv']['time-pos'])-frame) < .001
        assert data['mpv']['hdr-compute-peak'] == 'no'
        assert data['mpv']['tone-mapping'] == 'auto' and data['mpv']['dither'] == 'no'
        windows = 'surface' in data
        if windows:
            surface = data['surface']
            assert surface['format'] == 'R10G10B10A2_UNORM' and surface['outputColorSpace'] == 'sdr'
            width, height = surface['width'], surface['height']
            image_width = min(width, height*4)
            raw = stem.with_suffix('.raw').read_bytes()
            assert len(raw) == width*height*4
            rows = [height//2-1,height//2,height//2+1]
        else:
            header,raw = Path(str(stem)+'-egl.bin').read_bytes().split(b'\n',1)
            surface = json.loads(header)
            assert all(surface[k] == 0 for k in ['priorError','setupError','readError'])
            assert surface['bits'] == [10,10,10,2] and not surface['pq']
            assert surface['dataspace'] == 0 and surface['eglColor'] == 12426
            assert surface['rows'] == 5 and surface['sequence'] <= 64
            width, height = surface['width'], surface['height']
            assert len(raw) == width*5*4
            target = json.loads(data['mpv']['video-target-params'])
            assert target['gamma'] == 'gamma2.2' and target['primaries'] == 'bt.709'
            assert target['max-luma'] == 203
            image_width = target['w']
            rows = range(5)
        observations = []
        for s in fixture['samples'][frame]:
            x = round((width-image_width)/2+s['x']*image_width/fixture['width']-.5)
            pixels = [struct.unpack_from('<I',raw,(row*width+x)*4)[0] for row in rows]
            rgb = [statistics.median((v>>(10*c))&1023 for v in pixels)/1023 for c in range(3)]
            observations.append({'x':s['x'],'reference':s['rgb'],'actual':rgb,
                                 'errorCodes':[abs(x-y)*1023 for x,y in zip(rgb,s['rgb'])]})
        errors = [v for o in observations for v in o['errorCodes']]
        maximum = max(errors)
        results.append({'frame':frame,'maxErrorCodes':maximum,'meanErrorCodes':statistics.mean(errors),
                        'passed':maximum <= fixture['flatInteriorTolerance10bitCodes'],
                        'decoder':data['mpv']['hwdec-current'],'source':source,'surface':surface,
                        'observations':observations})
    report={'tag':a.tag,'fixtureSha256':fixture['sha256'],
            'thresholdCodes':fixture['flatInteriorTolerance10bitCodes'],
            'scope':'HLG to SDR digital flat-interior acceptance; no native HLG, PixelCopy or physical measurement',
            'frames':results}
    (a.evidence/(a.tag+'-result.json')).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'tag':a.tag,'frames':[{k:v for k,v in r.items() if k in ['frame','maxErrorCodes','passed','decoder']} for r in results]}))
    if not all(r['passed'] for r in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()

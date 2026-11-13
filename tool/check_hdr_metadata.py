"""Summarize controlled metadata observations; never mark full DV/HDR10+ fidelity."""
import array
import json
from pathlib import Path


def main():
    root = Path('docs/verification/hdr-output-20261109')
    results = []
    for device in ['phone', 'tablet', 'windows']:
        for kind in ['hdr10plus', 'dv84', 'dv7']:
            tag = (f'{device}-{kind}-metadata-v2' if device != 'windows' else
                   'windows-dv7-v3-dv7' if kind == 'dv7' else f'windows-formats-v2-{kind}')
            states = []
            pixels = []
            for mode in ['on', 'off']:
                stem = root / f'{tag}-metadata-{mode}'
                data = json.loads(stem.with_suffix('.json').read_text())
                mpv = data['mpv']
                source = json.loads(mpv['video-out-params'])
                assert float(mpv['time-pos']) == 0
                if mode == 'off':
                    assert ('hdr10plus=no' if kind == 'hdr10plus' else 'dolbyvision=no') in mpv['vf']
                if kind == 'hdr10plus':
                    assert ('scene-max-r' in source) == (mode == 'on')
                else:
                    assert (source['colormatrix'] == 'dolbyvision') == (mode == 'on')
                if device == 'windows':
                    surface = data['surface']
                    assert surface['format'] == 'R10G10B10A2_UNORM'
                    assert surface['outputColorSpace'] == 'sdr'
                    raw = stem.with_suffix('.raw').read_bytes()
                    assert len(raw) == surface['width']*surface['height']*4
                    target = 'sdr'
                else:
                    header,raw = Path(str(stem)+'-egl.bin').read_bytes().split(b'\n',1)
                    surface = json.loads(header)
                    assert surface['bits'] == [10,10,10,2]
                    assert all(surface[k] == 0 for k in ['priorError','setupError','readError'])
                    assert len(raw) == surface['width']*5*4 and surface['sequence'] <= 64
                    target = json.loads(mpv['video-target-params'])['gamma']
                    assert (target == 'pq') == surface['pq']
                    assert surface['dataspace'] == (0x09c60000 if surface['pq'] else 0)
                values = array.array('I');values.frombytes(raw);pixels.append(values)
                states.append({'mode':mode,'postFilter':source,'filter':mpv['vf'],
                               'target':target,'decoder':mpv['hwdec-current'],'surface':surface})
            assert len(pixels[0]) == len(pixels[1])
            comparable = states[0]['target'] == states[1]['target']
            delta = max(abs(((a>>(c*10))&1023)-((b>>(c*10))&1023))
                        for a,b in zip(*pixels) for c in range(3)) if comparable else None
            results.append({'tag':tag,'device':device,'format':kind,'states':states,
                            'sameOutputEncoding':comparable,'maxCodeDelta':delta,
                            'changedPixels':sum(a!=b for a,b in zip(*pixels)) if comparable else None,
                            'fullFormatPictureAcceptance':False})
    report={'scope':'Same first frame, metadata parser/filter/output boundary. Not physical output or full dynamic-format fidelity.',
            'observations':results,
            'limitations':['Windows DV8.4 on state retains hdr10plus=no from previous case; this DV8.4 sample has no HDR10+ side data.',
                           'No valid Profile 5 or 8.1 fixture was exercised. Profile 7 is one frame, not every MEL/FEL variant.',
                           'DV8.4 off state still reports light=display, so it is not accepted as correct scene-referred HLG fallback.',
                           'Different PQ/SDR output encodings are not numerically compared.']}
    (root/'format-metadata-results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps([{k:v for k,v in r.items() if k not in ['states']} for r in results]))


if __name__ == '__main__':
    main()

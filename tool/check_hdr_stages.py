"""Offline analysis of bounded Android GL stage probes; never measures a panel."""
import argparse
import json
from pathlib import Path
import re
import struct


def read(path):
    header, data = path.read_bytes().split(b'\n', 1)
    h = json.loads(header)
    assert not any(h[k] for k in ('prior', 'setup', 'error')), h
    assert h['status'] == 0x8CD5 and h['seq'] <= 192, h
    kind = {5125: '<4I', 5126: '<4f', 33640: '<I'}[h['type']]
    values = list(struct.iter_unpack(kind, data))
    assert len(values) == h['width']
    if h['type'] == 33640:
        values = [tuple((v[0] >> (c*10) & 1023)/1023 for c in range(3)) for v in values]
    return h, values


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tag', required=True)
    p.add_argument('--evidence', type=Path, default=Path('docs/verification/hdr-output-20261109'))
    p.add_argument('--fixture', type=Path, default=Path('.dart_tool/hdr-pattern'))
    args = p.parse_args()
    fixture = json.loads(args.fixture.with_suffix('.json').read_text())
    yuv = args.fixture.with_suffix('.yuv').read_bytes()
    frames = []
    for frame in (0, 2):
        prefix = f'{args.tag}-pattern-{frame}-stage-'
        shaders = {f.stem.removeprefix(prefix): f.read_text()
                   for f in args.evidence.glob(prefix+'*.frag')}
        def program(marker):
            found = [key for key, text in shaders.items() if marker in text]
            assert len(found) == 1, found
            return found[0]
        merge = program('// merging plane')
        luma = program('// use_integer fix')
        matrix = program('mat3(colormatrix) * color.rgb')
        def texture(prog, name):
            return read(args.evidence / f'{prefix}{prog}-{name}.bin')
        _, sy = texture(luma, 'texture0')
        _, su = texture(merge, 'texture0')
        _, sv = texture(merge, 'texture1')
        _, normalized_y = texture(luma, 'output')
        _, normalized_uv = texture(merge, 'output')
        _, rgb = texture(matrix, 'output')
        source = [[struct.unpack_from('<H', yuv, ((frame*3+c)*1024*256+128*1024+x)*2)[0]
                   for c in range(3)] for x in range(1024)]
        source_errors = [abs(values[x][0]-source[x][c])
                         for x in range(1024) for c, values in enumerate((sy, su, sv))]
        uniforms = {}
        for line in (args.evidence / f'{prefix}{matrix}-uniforms.txt').read_text().splitlines():
            fields = line.split()
            uniforms[fields[1]] = [float(x) for x in fields[2:]]
        m, offset = uniforms['colormatrix'], uniforms['colormatrix_c']
        coefficient = float(re.search(r'color\.r = ([0-9.e+-]+) \*', shaders[luma])[1])
        final = json.loads((args.evidence / f'{args.tag}-egl-result.json').read_text())['frames'][frame//2]
        observations = []
        for sample, window in zip(fixture['samples'][frame], final['observations'], strict=True):
            x = sample['x']
            assert x == window['sourceX']
            norm = [normalized_y[x][0], *normalized_uv[x][:2]]
            prediction = [sum(m[c*3+r]*norm[c] for c in range(3))+offset[r] for r in range(3)]
            ideal = source[x]
            observations.append({'x':x, 'sourceYuv':ideal, 'normalizedGpu':norm,
                'normalizedErrorCodes':[(norm[c]-ideal[c]/1020)*1023 for c in range(3)],
                'matrixGpu':rgb[x][:3], 'matrixFromCapturedInputs':prediction,
                'matrixStoreDeltaCodes':[(rgb[x][c]-prediction[c])*1023 for c in range(3)],
                'matrixErrorCodes':[(max(0,min(1,rgb[x][c]))-sample['rgb'][c])*1023 for c in range(3)],
                'matrixToWindowCodes':[(window['egl'][c]-max(0,min(1,rgb[x][c])))*1023 for c in range(3)]})
        def max_error(key):
            return max(abs(v) for point in observations for v in point[key])
        frames.append({'frame':frame,'sourceTextureMaxIntegerError':max(source_errors),
            'normalizationShaderCoefficient':coefficient,'exactCoefficient':1/1020,
            'normalizationMaxErrorCodes':max_error('normalizedErrorCodes'),
            'matrixMaxErrorCodes':max_error('matrixErrorCodes'),
            'matrixStoreMaxDeltaCodes':max_error('matrixStoreDeltaCodes'),
            'matrixToWindowMaxCodes':max_error('matrixToWindowCodes'),
            'observations':observations})
    report = {'tag':args.tag,'scope':'Captured GL inputs and intermediate float FBO; not panel output','frames':frames}
    (args.evidence / f'{args.tag}-stages-result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({**report,'frames':[{k:v for k,v in f.items() if k!='observations'} for f in frames]}))


if __name__ == '__main__':
    main()

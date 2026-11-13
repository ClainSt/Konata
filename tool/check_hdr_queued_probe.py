"""Compare same-swap RGB10 window, last queued AHB, and PixelCopy central row."""
import argparse
import json
from pathlib import Path
import statistics
import struct


def rgb10(data, pixel):
    value, = struct.unpack_from('<I', data, pixel*4)
    assert value >> 30 == 3, 'Unexpected non-opaque source'
    return [(value >> (c*10)) & 1023 for c in range(3)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--frame', type=int, default=2)
    parser.add_argument('--evidence', type=Path, default=Path('docs/verification/hdr-output-20261109'))
    args = parser.parse_args()
    base = args.evidence / f'{args.tag}-pattern-{args.frame}'
    meta = json.loads(base.with_suffix('.json').read_text())
    eh, before = Path(str(base)+'-egl.bin').read_bytes().split(b'\n',1)
    qh, queued = Path(str(base)+'-queued.bin').read_bytes().split(b'\n',1)
    eh, qh = json.loads(eh), json.loads(qh)
    assert eh['sequence'] == qh['sequence'] <= 64
    assert eh['bits'] == [10,10,10,2] and eh['pq']
    assert all(eh[k] == 0 for k in ('priorError','setupError','readError'))
    assert all(qh[k] == 0 for k in ('result','prior','setup','error'))
    assert qh['status'] == 0x8CD5 and qh['eglError'] == 0x3000
    assert not qh['fencePresent'] or qh['wait'] == 1
    assert qh['format'] == 43 and qh['dataspace'] == 0x9c60000
    assert qh['crop'] in ([0,0,0,0], [0,0,qh['width'],qh['height']]), qh
    w,h = qh['width'],qh['height']
    transform = qh['transform']
    assert transform in range(8)
    lw,lh = (h,w) if transform & 4 else (w,h)
    assert (lw,lh) == (eh['width'],eh['height'])
    assert len(queued) == (w+h)*5*4
    assert float(meta['mpv']['time-pos']) == args.frame
    surface = meta['surface']
    assert surface['readback'] == 'RGBA_F16'
    copied = base.with_suffix('.raw').read_bytes()
    row = lh//2
    samples=[]
    for x in range(lw):
        # Invert AOSP Readback's flips followed by clockwise 90-degree rotation.
        rx,ry = (row,h-1-x) if transform & 4 else (x,row)
        if transform & 1: rx=w-1-rx
        if transform & 2: ry=h-1-ry
        if abs(ry-h//2)<=2:
            index=(ry-(h//2-2))*w+rx
        else:
            assert abs(rx-w//2)<=2
            index=w*5+ry*5+rx-(w//2-2)
        raw=rgb10(queued,index)
        pre=rgb10(before,2*lw+x)
        rgba=struct.unpack_from('<4e',copied,row*surface['rowBytes']+x*8)
        assert rgba[3] == 1, 'Unexpected non-opaque PixelCopy result'
        pc=rgba[:3]
        ideal=[struct.unpack('<e',struct.pack('<e',v/1023))[0] for v in raw]
        samples.append({'x':x,'egl':pre,'queued':raw,'pixelCopy':pc,
            'submissionDeltaCodes':[a-b for a,b in zip(raw,pre)],
            'copyDeltaCodes':[a*1023-b for a,b in zip(pc,raw)],
            'idealF16DeltaCodes':[a*1023-b for a,b in zip(ideal,raw)],
            'conversionBeyondF16Codes':[(a-b)*1023 for a,b in zip(pc,ideal)]})
    def errors(key):
        values=[abs(v) for sample in samples for v in sample[key]]
        return {'max':max(values),'mean':statistics.mean(values),'nonzeroChannels':sum(v!=0 for v in values)}
    result={'tag':args.tag,'frame':args.frame,'scope':'Own submitted AHB, before compositor; not panel output',
        'eglHeader':eh,'queuedHeader':qh,'centralRowPixels':lw,
        'submissionDifference':errors('submissionDeltaCodes'),'pixelCopyDifference':errors('copyDeltaCodes'),
        'idealF16Quantization':errors('idealF16DeltaCodes'),
        'conversionBeyondF16':errors('conversionBeyondF16Codes'),
        'negativePixelCopyChannels':sum(v<0 for sample in samples for v in sample['pixelCopy']),
        'samples':samples}
    (args.evidence/f'{args.tag}-queued-result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='samples'}))


if __name__=='__main__': main()

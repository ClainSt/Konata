"""Bounded HLG Main10 fixture and CPU reference for the pinned vo=gpu SDR policy.

BT.2100 inverse OETF/OOTF, BT.2390 EETF, then BT.2020->709 and gamma2.2.
This is a mathematical policy reference, not another renderer or physical meter.
Only flat patch interiors are compared; predeclared tolerance is 2 RGB10 codes
for FP16 intermediates, shader arithmetic and final RGB10 rounding. It does not
replace or relax the previous PQ identity-path one-code gate.
"""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import subprocess

LUMA = [.2627, .6780, .0593]


def dot(a, b):
    return sum(x*y for x,y in zip(a,b))


def mul(a, v):
    return [dot(row,v) for row in a]


def inverse(a):
    rows = [list(row)+[float(i == j) for j in range(3)] for i,row in enumerate(a)]
    for i in range(3):
        pivot = rows[i][i]
        rows[i] = [v/pivot for v in rows[i]]
        for j in range(3):
            if i != j:
                factor = rows[j][i]
                rows[j] = [a-factor*b for a,b in zip(rows[j], rows[i])]
    return [row[3:] for row in rows]


def matrix(primaries):
    columns = [[x/y, 1, (1-x-y)/y] for x,y in primaries]
    rows = list(map(list, zip(*columns)))
    scale = mul(inverse(rows), [.3127/.3290, 1, (1-.3127-.3290)/.3290])
    return [[v*s for v,s in zip(row,scale)] for row in rows]


SRC = matrix([(.708,.292),(.170,.797),(.131,.046)])
DST = matrix([(.64,.33),(.30,.60),(.15,.06)])
TO709 = [[dot(row,col) for col in zip(*SRC)] for row in inverse(DST)]


def pq(nits):
    p = (nits/10000)**(2610/16384)
    return ((3424/4096 + 2413/128*p)/(1+2392/128*p))**(2523/32)


def unpq(v):
    p = max(0, v)**(32/2523)
    return 10000*(max(0, p-3424/4096)/(2413/128-2392/128*p))**(16384/2610)


def eef(nits, peak=1000, target=203):
    top = pq(peak)
    v = pq(min(nits, peak))/top
    maximum = pq(target)/top
    knee = 1.5*maximum-.5
    if v >= knee:
        t = (v-knee)/(1-knee)
        v = (2*t**3-3*t**2+1)*knee + (t**3-2*t**2+t)*(1-knee) + (-2*t**3+3*t**2)*maximum
    return unpq(v*top)


def codes(rgb):
    y = dot(LUMA, rgb)
    return [round(64+876*y), round(512+896*(rgb[2]-y)/1.8814),
            round(512+896*(rgb[0]-y)/1.4746)]


def encoded(yuv):
    y, cb, cr = (yuv[0]-64)/876, (yuv[1]-512)/896, (yuv[2]-512)/896
    red, blue = y+1.4746*cr, y+1.8814*cb
    green = (y-.2627*red-.0593*blue)/.6780
    return [min(1,max(0,v)) for v in [red,green,blue]]


def reference(yuv):
    rgb = encoded(yuv)
    scene = [v*v/3 if v <= .5 else
             (math.exp((v-.55991073)/.17883277)+.28466892)/12 for v in rgb]
    light = [1000*v*max(dot(LUMA, scene), 1e-9)**.2 for v in scene]
    if max(light) < 1e-10:
        return [0., 0., 0.]
    mapped = [eef(v)/203 for v in light]
    idx = light.index(max(light))
    coeff = .90*(max(mapped[idx]-.18, 1e-6)/max(mapped[idx], 1))**.20
    out = [(v/203)*(mapped[idx]/(light[idx]/203))*(1-coeff)+m*coeff for v,m in zip(light,mapped)]
    out = mul(TO709, out)
    if min(out) < 0:
        luma = dot([.2126,.7152,.0722],out)
        c = min(out)/(min(out)-luma)
        out = [v*(1-c)+luma*c for v in out]
    if max(out) > 1:
        top = max(out)
        out = [v/top for v in out]
    return [min(1,max(0,v))**(1/2.2) for v in out]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ffmpeg', required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    gray = [0,.01,.05,.1,.18,.25,.4,.5,.6,.65,.7,.75,.8,.9,.95,1]
    color = [(v,v,v) for v in [.05,.2,.5,.75]] + [
        (.7,.2,.2),(.2,.7,.2),(.2,.2,.7),(.7,.7,.2),(.2,.7,.7),(.7,.2,.7),
        (.4,.5,.6),(.6,.5,.4),(.9,.7,.5),(.5,.7,.9),(.8,.8,.6),(.6,.8,.8)]
    patches = [[codes((v,v,v)) for v in gray], [codes(v) for v in color]]
    raw = b''
    for row in patches:
        for c in range(3):
            w, h = (1024,256) if c == 0 else (512,128)
            raw += array.array('H', [row[x//(w//16)][c] for _ in range(h) for x in range(w)]).tobytes()
    a.output.parent.mkdir(parents=True,exist_ok=True)
    rawfile=a.output.with_suffix('.yuv');rawfile.write_bytes(raw)
    params='lossless=1:pools=2:frame-threads=2:repeat-headers=1:colorprim=9:transfer=18:colormatrix=9:range=limited:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,0):max-cll=1000,400'
    subprocess.run([a.ffmpeg,'-v','warning','-y','-f','rawvideo','-pix_fmt','yuv420p10le','-s','1024x256','-r','1','-color_range','tv','-colorspace','bt2020nc','-color_primaries','bt2020','-color_trc','arib-std-b67','-i',str(rawfile),'-frames:v','2','-c:v','libx265','-preset','fast','-x265-params',params,'-color_range','tv','-colorspace','bt2020nc','-color_primaries','bt2020','-color_trc','arib-std-b67',str(a.output)],check=True)
    decoded=subprocess.check_output([a.ffmpeg,'-v','error','-i',str(a.output),'-pix_fmt','yuv420p10le','-f','rawvideo','-'])
    assert decoded==raw
    a.output.with_suffix('.json').write_text(json.dumps({'width':1024,'height':256,'pts':[0,1],
        'kind':'synthetic HEVC Main10 HLG, static mastering peak 1000 nits; not a camera/reference master',
        'losslessDecodeVerified':True,'sha256':hashlib.sha256(a.output.read_bytes()).hexdigest(),
        'target':'BT.709 gamma2.2 / 203 nits, pinned gpu auto=BT.2390, compute-peak=no',
        'flatInteriorTolerance10bitCodes':2.0,'pixelCopyUsed':False,
        'samples':[[{'x':i*64+32,'yuv':v,'rgb':reference(v)} for i,v in enumerate(row)] for row in patches]},indent=2)+'\n')


if __name__ == '__main__':
    main()

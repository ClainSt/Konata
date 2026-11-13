"""Generate a bounded, lossless 10-bit BT.2020/PQ diagnostic fixture.

Not bundled with the app. Flat interior tolerance is registered before capture:
1/1023, covering one RGB10 quantization and F16 readback, with no dithering.
Source peak is 203 cd/m², below both measured API target limits; this checks
PQ/range/matrix/precision without conflating display-peak tone mapping.
"""
import argparse
import array
import hashlib
import json
from pathlib import Path
import subprocess


def pq(nits):
    power = (nits / 10000) ** (2610 / 16384)
    return ((3424 / 4096 + 2413 / 128 * power) /
            (1 + 2392 / 128 * power)) ** (2523 / 32)


def yuv(rgb):
    red, green, blue = map(pq, rgb)
    y = .2627 * red + .6780 * green + .0593 * blue
    return [round(64 + 876 * y), round(512 + 896 * (blue - y) / 1.8814),
            round(512 + 896 * (red - y) / 1.4746)]


def rgb(codes):
    y, cb, cr = (codes[0] - 64) / 876, (codes[1] - 512) / 896, (codes[2] - 512) / 896
    red, blue = y + 1.4746 * cr, y + 1.8814 * cb
    green = (y - .2627 * red - .0593 * blue) / .6780
    return [min(1, max(0, v)) for v in (red, green, blue)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    levels = [0, .001, .005, .01, .05, .1, .5, 1, 5, 10, 25, 50, 100, 150, 200, 203]
    colors = [(100, 0, 0), (0, 100, 0), (0, 0, 100), (100, 100, 0),
              (0, 100, 100), (100, 0, 100), (1, 5, 20), (20, 5, 1),
              (1, 20, 5), (50, 100, 150), (150, 100, 50), (100, 50, 150),
              (5, 5, 5), (100, 100, 100), (203, 203, 203), (0, 0, 0)]
    rows = [[[64 + min(x // 2, 509), 512, 512] for x in range(1024)],
            [yuv((levels[x // 64],) * 3) for x in range(1024)],
            [yuv(colors[x // 64]) for x in range(1024)]]
    raw = b''.join(array.array('H', [row[x][channel] for _ in range(256)
                   for x in range(1024)]).tobytes() for row in rows for channel in range(3))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw_path = args.output.with_suffix('.yuv')
    raw_path.write_bytes(raw)
    parameters = ('lossless=1:pools=2:frame-threads=2:repeat-headers=1:'
                  'colorprim=9:transfer=16:colormatrix=9:range=limited:'
                  'master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(2030000,0):max-cll=203,203')
    subprocess.run([args.ffmpeg, '-v', 'warning', '-y', '-f', 'rawvideo', '-pix_fmt',
                    'yuv444p10le', '-s', '1024x256', '-r', '1',
                    '-color_range', 'tv', '-colorspace', 'bt2020nc',
                    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-i', str(raw_path),
                    '-frames:v', '3', '-c:v', 'libx265', '-preset', 'fast', '-x265-params',
                    parameters, '-color_range', 'tv', '-colorspace', 'bt2020nc',
                    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', str(args.output)], check=True)
    decoded = subprocess.check_output([args.ffmpeg, '-v', 'error', '-i', str(args.output),
                                      '-f', 'rawvideo', '-pix_fmt', 'yuv444p10le', '-'])
    if raw != decoded:
        raise ValueError('Encoded fixture is not lossless')
    args.output.with_suffix('.json').write_text(json.dumps({
        'width': 1024, 'height': 256, 'pts': [0, 1, 2], 'peakNits': 203,
        'flatInteriorTolerance10bitCodes': 1.0,
        'rampMinimumDistinctLevels': 257, 'dither': 'no',
        'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'losslessDecodeVerified': True,
        'sources': ['https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.pdf',
                    'https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2087-0-201510-I!!PDF-E.pdf'],
        'samples': [[{'x': 2*i + 1, 'rgb': rgb(row[2*i])} for i in range(510)]
                    if n == 0 else [{'x': i*64 + 32, 'rgb': rgb(row[i*64])}
                                    for i in range(16)] for n, row in enumerate(rows)]}, indent=2)+'\n')


if __name__ == '__main__':
    main()

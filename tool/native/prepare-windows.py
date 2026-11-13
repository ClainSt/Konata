from pathlib import Path
import tarfile
import argparse
import hashlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description='Prepare the pinned Windows cross-build in Linux.')
parser.add_argument('--root', type=Path, default=Path('/opt/konata-build'))
parser.add_argument('--sources', type=Path, required=True)
args = parser.parse_args()
root, sources = args.root, args.sources
root.mkdir(parents=True, exist_ok=True)
hashes = {
    'mpv-v0.42.0.tar.gz': 'a4a79fa6ca728762ac407734b0f93dbcbba250c3bb3bf97b77a342042be802e4',
    'ffmpeg-n9.0.2.tar.gz': '0aa2b1de2a5698b20a23e93d539a9a8e82ca0117496c5bdf05d198805f42bb3b',
}
for name, expected in hashes.items():
    with (sources / name).open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
            raise ValueError(f'Source checksum mismatch: {name}')
target = root / 'windows'
target.mkdir(exist_ok=True)
for name, archive, destination in [('mpv', 'mpv-v0.42.0.tar.gz', target), ('ffmpeg', 'ffmpeg-n9.0.2.tar.gz', target / 'ffmpeg')]:
    if not (destination / 'meson.build' if name == 'mpv' else destination / 'configure').exists():
        destination.mkdir(exist_ok=True)
        with tarfile.open(sources / archive) as tf:
            for member in tf.getmembers():
                components = member.name.split('/', 1)
                if len(components) == 1 or not components[1]:
                    continue
                member.name = components[1]
                tf.extract(member, destination, filter='data')
for name in ['dovi-hlg-fallback.patch', 'windows-dovi-base-metadata.patch',
             'windows-d3d11-strict-float.patch', 'windows-d3d11-low10-upload.patch',
             'windows-p010-repack.patch']:
    patch = Path(__file__).with_name(name).resolve()
    if subprocess.run(['patch', '-d', str(target), '-p1', '--forward', '--dry-run', '-i', str(patch)], capture_output=True).returncode == 0:
        subprocess.run(['patch', '-d', str(target), '-p1', '-i', str(patch)], check=True)
    else:
        subprocess.run(['patch', '-d', str(target), '-p1', '--reverse', '--dry-run', '-i', str(patch)], check=True)
script = (target / 'ci/build-mingw64-full.sh').read_text()
script = script.replace('. ./ci/build-common.sh', '''. ./ci/build-common.sh
# The image follows FFmpeg master; use options supported by pinned FFmpeg 9.0.2.
# Encoding and devices are disabled below; keep playback, network and GPU paths.
FF_CONFIGURE="--enable-version3 --disable-debug --disable-w32threads --enable-pthreads --enable-iconv --enable-zlib --enable-libxml2 --enable-lzma --enable-libdav1d --enable-libopus --enable-libvorbis --enable-schannel --enable-ffnvcodec --enable-cuda-llvm --enable-vulkan --enable-libplacebo --enable-libass --enable-libfreetype --enable-libharfbuzz --enable-libfribidi --enable-libsoxr --enable-libzimg --enable-libopenjpeg --enable-libwebp --enable-libjxl --enable-lcms2 --enable-libbluray"
''', 1)
def replace_once(old, new):
    global script
    assert script.count(old) == 1, old
    script = script.replace(old, new, 1)

replace_once('$gitclone https://github.com/FFmpeg/FFmpeg.git ffmpeg', 'test "$(cat ffmpeg/RELEASE)" = 9.0.2')
replace_once('--disable-{librav1e,librsvg,openal}', '--disable-{librav1e,librsvg,openal,encoders,muxers,devices} --enable-encoder=mjpeg,png --enable-muxer=spdif,matroska,mov,mpegts')
replace_once('$gitclone -b v2.1 https://github.com/LuaJIT/LuaJIT.git', '''if [ ! -d LuaJIT ]; then
    git init LuaJIT
    git -C LuaJIT remote add origin https://github.com/LuaJIT/LuaJIT.git
    git -C LuaJIT fetch --depth 1 origin ea9eb7edb5eac4a9d175d74523db34fac0fa5180
    git -C LuaJIT checkout --detach FETCH_HEAD
fi''')
replace_once('$gitclone https://github.com/libarchive/libarchive.git', '[ -d libarchive ] || $gitclone -b v3.8.11 https://github.com/libarchive/libarchive.git')
replace_once('$gitclone -b v0.0.8 https://gitlab.freedesktop.org/uchardet/uchardet.git', '[ -d uchardet ] || $gitclone -b v0.0.8 https://gitlab.freedesktop.org/uchardet/uchardet.git')
for directory, revision in [
    ('LuaJIT', 'ea9eb7edb5eac4a9d175d74523db34fac0fa5180'),
    ('libarchive', '03036ffa409a2aa1c5bbad35be2202641a040fda'),
    ('uchardet', 'ae6302a016088ad07177f86d417b20010053632b'),
]:
    replace_once(f'pushd {directory}',
                 f'test "$(git -C {directory} rev-parse HEAD)" = {revision}\npushd {directory}')
replace_once('meson wrap install mujs', 'test -f subprojects/mujs.wrap')
(target / 'subprojects').mkdir(exist_ok=True)
shutil.copyfile(Path(__file__).with_name('mujs.wrap'), target / 'subprojects/mujs.wrap')
# Keep libass as the subtitle renderer; terminal sixel and desktop media controls
# are not used by Konata. Preserve GPU renderers, color management and scripting.
for start, end in [('group "Building libsixel"', 'group "Building libarchive"'), ('group "Building subrandr"', 'group "Building mpv"')]:
    a, b = script.index(start), script.index(end)
    script = script[:a] + script[b:]
replace_once('-D{shaderc,sixel,spirv-cross,subrandr,uchardet,vapoursynth,vulkan}=enabled', '-D{shaderc,spirv-cross,uchardet,vulkan}=enabled\n    -D{sixel,subrandr,vapoursynth}=disabled')
replace_once('-D{win32-smtc,zimg}=enabled', '-Dwin32-smtc=disabled -Dzimg=enabled')
script = script.replace('$(nproc)', '${KONATA_JOBS:-2}')
# Keep the GCC runtime static, as in the shipped native library.
script = script.replace('-L$FFBUILD_PREFIX/lib -liconv"',
                        '-L$FFBUILD_PREFIX/lib -liconv -static-libgcc"')
script = script.replace('ninja install', 'ninja -j"${KONATA_JOBS:-2}" install')
script = script.replace('ninja cppwinrt', 'ninja -j"${KONATA_JOBS:-2}" cppwinrt')
script = script.replace('meson compile -C build', 'meson compile -C build -j "${KONATA_JOBS:-2}"')
(target / 'ci/build-konata-windows.sh').write_text(script)
print('Prepared pinned Windows build recipe')

"""Stage built native artifacts without modifying any application or release."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['windows', 'android'])
    parser.add_argument('--root', type=Path, default=Path('/opt/konata-build'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--android-helper-jar', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    target = output / args.platform
    target.mkdir(parents=True, exist_ok=True)
    mpv_source = (args.root / 'windows' if args.platform == 'windows' else
                  args.root / 'mpv-android-255901dd586fa750000fa0075f69d6ffdd26cd9c/buildscripts/deps/mpv')
    subprocess.run(['patch', '-d', str(mpv_source), '-p1', '--reverse', '--dry-run'],
                   input=Path(__file__).with_name('dovi-hlg-fallback.patch').read_bytes(),
                   check=True, stdout=subprocess.DEVNULL)
    if args.platform == 'windows':
        for name in ['windows-dovi-base-metadata.patch', 'windows-d3d11-strict-float.patch',
                     'windows-d3d11-low10-upload.patch', 'windows-p010-repack.patch']:
            patch = Path(__file__).with_name(name)
            subprocess.run(['patch', '-d', str(mpv_source), '-p1', '--reverse', '--dry-run'],
                           input=patch.read_bytes(), check=True, stdout=subprocess.DEVNULL)
        build = args.root / 'windows'
        for name in ['libmpv-2.dll', 'libmpv.dll.a', 'LICENSE.LGPL']:
            shutil.copy2(build / 'artifact-libmpv' / name, target / name)
        shutil.copytree(build / 'artifact-libmpv/include', target / 'include', dirs_exist_ok=True)
        (target / 'reference').mkdir(exist_ok=True)
        for name in ['mpv.exe', 'mpv.com']:
            shutil.copy2(build / 'artifact' / name, target / 'reference' / name)
        platform = 'windows-x64'
    else:
        jar = args.android_helper_jar
        if not jar or sha256(jar) != '4363dfa5d3d415b91c1f16f6fb90c3fe59a77dfd3f9b824d2b24b492d6b09df9':
            parser.error('Provide the pinned media-kit v1.1.7 ARM64 JAR (SHA-256 mismatch).')
        build = args.root / 'mpv-android-255901dd586fa750000fa0075f69d6ffdd26cd9c/buildscripts'
        patch = Path(__file__).with_name('android-hdr.patch')
        subprocess.run(['patch', '-d', str(build / 'deps/mpv'), '-p1', '--reverse',
                        '--dry-run'], input=patch.read_bytes(), check=True,
                       stdout=subprocess.DEVNULL)
        ndk = build / 'sdk/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64'
        abi = target / 'arm64-v8a'
        abi.mkdir(exist_ok=True)
        libraries = list((build / 'prefix/arm64/lib').glob('*.so'))
        if not libraries:
            raise ValueError('Missing built ARM64 libraries')
        for source in libraries:
            shutil.copy2(source, abi / source.name)
        shutil.copy2(ndk / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so', abi)
        subprocess.run([str(ndk / 'bin/llvm-strip'), '--strip-unneeded',
                        *map(str, abi.glob('*.so'))], check=True)
        # Only the unchanged JNI helper is reused. Never copy the old libmpv.
        with zipfile.ZipFile(jar) as archive:
            (abi / 'libmediakitandroidhelper.so').write_bytes(
                archive.read('lib/arm64-v8a/libmediakitandroidhelper.so'))
        platform = 'android-arm64'
    files = {
        file.relative_to(output).as_posix(): {'sha256': sha256(file), 'bytes': file.stat().st_size}
        for file in sorted(target.rglob('*'))
        if file.is_file() and 'reference' not in file.relative_to(target).parts
    }
    manifest = {
        'mpv': '0.42.0', 'ffmpeg': '9.0.2', 'platform': platform, 'files': files,
    }
    patch_names = ['dovi-hlg-fallback.patch'] + (
        ['windows-dovi-base-metadata.patch', 'windows-d3d11-strict-float.patch',
         'windows-d3d11-low10-upload.patch', 'windows-p010-repack.patch']
        if args.platform == 'windows' else ['android-hdr.patch'])
    manifest['patches'] = {
        name: sha256(Path(__file__).with_name(name)) for name in patch_names
    }
    (output / f'{args.platform}-manifest.json').write_text(
        json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'platform': platform, 'bytes': sum(f['bytes'] for f in files.values())}))


if __name__ == '__main__':
    main()

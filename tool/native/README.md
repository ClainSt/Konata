# Konata native build recipes

These recipes preserve the pinned Linux/WSL cross-build for the Windows x64 `libmpv-2.dll` and Android ARM64 shared library set. They do not install or publish the app, include test media, or change the public Android signature.

Use Linux storage for `KONATA_BUILD_ROOT` (tested: `/opt/konata-build`), not an NTFS-mounted working tree. Ubuntu 24.04, Python 3.12, build-essential, Git, curl, wget, unzip, autoconf, automake, libtool, pkg-config, CMake, Ninja, NASM, gperf, Python venv and Podman were used. Keep compilation concurrency at 2 initially. No permanent container service is required. The default staging directory is `native/konata-native/` at the repository root (or override via `KONATA_NATIVE_ROOT`).

## Sources

Download these commit archives as the filenames shown. The preparation scripts check their SHA-256 before extraction:

- `mpv-v0.42.0.tar.gz`: https://codeload.github.com/mpv-player/mpv/tar.gz/b0841e8c4d156b8403dc1876c4cbd9011eb583f3
- `ffmpeg-n9.0.2.tar.gz`: https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/946fcce07b6dcd0331c8cc609192aeff5e1924f8

Windows uses image
`ghcr.io/btbn/ffmpeg-builds/win64-lgpl@sha256:d2290020ecfd15e95366c828f236c7e3d8066fd6a92507d93b6b119bc3aed48a`.
Its bundled cross-toolchain/static dependencies are pinned as an image; they are not independently rebuilt by these scripts.

Android uses the mpv-android repository commit `255901dd586fa750000fa0075f69d6ffdd26cd9c` (`SHA-256: 10750e25fb2f1097f5df55a409df6d962279a0923d7c31ed25701120190176f4`).

## Build

`dovi-hlg-fallback.patch` preserves source HDR metadata before Dolby Vision mapping and restores HLG scene light and that metadata when using the HLG base layer. Both build preparations apply it; staging verifies it. Android's HDR patch chooses the EGL output from the restored base-layer parameters.

```sh
export KONATA_BUILD_ROOT=/opt/konata-build
export KONATA_SOURCES=/path/to/source-archives
export KONATA_NATIVE_ROOT=/path/to/Konata/native/konata-native
export KONATA_JOBS=2

# Windows: prepare from the official mpv CI recipe, then run it in the pinned image.
python3 tool/native/prepare-windows.py --root "$KONATA_BUILD_ROOT" --sources "$KONATA_SOURCES"
podman run --name konata-windows-build --cpus=2 --memory=4g \
  -e KONATA_JOBS=2 -v "$KONATA_BUILD_ROOT/windows:/mpv" -w /mpv \
  ghcr.io/btbn/ffmpeg-builds/win64-lgpl@sha256:d2290020ecfd15e95366c828f236c7e3d8066fd6a92507d93b6b119bc3aed48a \
  bash ci/build-konata-windows.sh
python3 tool/native/stage.py windows --root "$KONATA_BUILD_ROOT" --output "$KONATA_NATIVE_ROOT"

# Android: NDK r30 is checked against Google's archive checksum.
bash tool/native/prepare-ndk.sh
bash tool/native/prepare-android.sh
export PATH="$KONATA_BUILD_ROOT/venv/bin:$PATH"
export cores=2
(cd "$KONATA_BUILD_ROOT/mpv-android-255901dd586fa750000fa0075f69d6ffdd26cd9c/buildscripts" && ./buildall.sh --arch arm64 mpv)
python3 tool/native/stage.py android --root "$KONATA_BUILD_ROOT" --output "$KONATA_NATIVE_ROOT" \
  --android-helper-jar /path/to/default-arm64-v8a.jar
```

The Android helper JAR is media-kit release v1.1.7 from
`https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-arm64-v8a.jar`.
`stage.py` checks its SHA-256 and extracts only `libmediakitandroidhelper.so`.

Windows reference `mpv.exe` stays under `reference/` and is not part of the application library manifest. Retain the generated `*-manifest.json` files in `native/konata-native/` so Flutter's local packaging adapters verify hashes, versions, and platform before use.

## Platform patches

- **Android (`android-hdr.patch`)**: Adds `android-hdr-peak` (zero disables native HDR), negotiates a 10-bit BT.2020/PQ EGL surface before rendering PQ content, and preserves float precision (`%.9e`) for `copy_image` 10-bit YUV normalization.
- **Windows (`windows-dovi-base-metadata.patch`, `windows-d3d11-strict-float.patch`, `windows-d3d11-low10-upload.patch`, `windows-p010-repack.patch`)**: Restores HDR10 base-layer luminance metadata during DV fallback, enforces IEEE-strict pixel shaders with a bumped D3D shader-cache version, selects P010 instead of low-aligned planar R16 upload on D3D11 while preserving `hdr_orig`, and uses FFmpeg's unscaled repack for identical-parameter `yuv420p10` -> P010 conversion.
- **Stand-alone probe (`d3d11_probe.cpp`)**: Test executable (not part of the application) linking against the staged mpv headers and D3D11/DXGI system import libraries.

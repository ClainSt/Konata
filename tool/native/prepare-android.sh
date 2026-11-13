#!/usr/bin/env bash
set -euo pipefail
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${KONATA_BUILD_ROOT:-/opt/konata-build}
upstream=$root/mpv-android-255901dd586fa750000fa0075f69d6ffdd26cd9c/buildscripts
sources=${KONATA_SOURCES:?Set KONATA_SOURCES to the verified source archive directory}
printf '%s  %s\n' a4a79fa6ca728762ac407734b0f93dbcbba250c3bb3bf97b77a342042be802e4 "$sources/mpv-v0.42.0.tar.gz" 0aa2b1de2a5698b20a23e93d539a9a8e82ca0117496c5bdf05d198805f42bb3b "$sources/ffmpeg-n9.0.2.tar.gz" | sha256sum -c -
python3 -m venv "$root/venv"
"$root/venv/bin/pip" install 'meson==1.11.0'
cd "$upstream"
mkdir -p deps sdk
for name in mpv ffmpeg; do
    if [ ! -d "deps/$name" ]; then
        mkdir "deps/$name"
        archive=mpv-v0.42.0.tar.gz
        [ "$name" = ffmpeg ] && archive=ffmpeg-n9.0.2.tar.gz
        tar -xzf "$sources/$archive" -C "deps/$name" --strip-components=1
    fi
done
if patch -d deps/mpv -p1 --forward --dry-run < "$recipe_dir/android-hdr.patch" >/dev/null 2>&1; then
    patch -d deps/mpv -p1 --forward < "$recipe_dir/android-hdr.patch"
elif ! patch -d deps/mpv -p1 --reverse --dry-run < "$recipe_dir/android-hdr.patch" >/dev/null 2>&1; then
    printf 'Android HDR patch does not match the pinned source\n' >&2
    exit 1
fi
# Preseed every upstream floating checkout with a release tag.
if patch -d deps/mpv -p1 --forward --dry-run < "$recipe_dir/dovi-hlg-fallback.patch" >/dev/null 2>&1; then
    patch -d deps/mpv -p1 --forward < "$recipe_dir/dovi-hlg-fallback.patch"
else
    patch -d deps/mpv -p1 --reverse --dry-run < "$recipe_dir/dovi-hlg-fallback.patch"
fi
[ -d deps/dav1d ] || git clone --depth 1 --branch 1.5.4 https://github.com/videolan/dav1d.git deps/dav1d
[ -d deps/libass ] || git clone --depth 1 --branch 0.17.5 https://github.com/libass/libass.git deps/libass
[ -d deps/libplacebo ] || git clone --depth 1 --branch v7.387.0 https://github.com/haasn/libplacebo.git deps/libplacebo
git -C deps/libplacebo submodule update --init --recursive --depth 1
export IN_CI=1
export WGET='wget --timeout=30 --tries=2 --no-verbose'
bash -o pipefail include/download-deps.sh
test "$(git -C deps/dav1d rev-parse HEAD)" = 54706fc6bc0cdecab7e9593974a4039cc038fca7
test "$(git -C deps/libass rev-parse HEAD)" = 4a05d8127f525943ebf45fdc6497c9e665947f0d
test "$(git -C deps/libplacebo rev-parse HEAD)" = 275f7dea27924cdd34ab2e6c20e448b6bc4fab65
test "$(git -C deps/freetype2 rev-parse HEAD)" = 37515cf56ba3349656049edbed89ffc6f6466f2d
printf 'Android sources ready\n'

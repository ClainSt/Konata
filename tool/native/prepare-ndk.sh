#!/usr/bin/env bash
set -euo pipefail
root=${KONATA_BUILD_ROOT:-/opt/konata-build}
sdk=$root/mpv-android-255901dd586fa750000fa0075f69d6ffdd26cd9c/buildscripts/sdk
mkdir -p "$sdk"
cd "$sdk"
if [ ! -d android-ndk-r30 ]; then
    curl -fL --retry 2 --connect-timeout 20 --max-time 1200 https://dl.google.com/android/repository/android-ndk-r30-linux.zip -o android-ndk-r30-linux.zip
    echo '5107f898313790e449e87eee2183d9a20602dee9  android-ndk-r30-linux.zip' | sha1sum -c -
    sha256sum android-ndk-r30-linux.zip > ndk-sha256.txt
    unzip -q android-ndk-r30-linux.zip
fi
grep -F '30.0.16248370' android-ndk-r30/source.properties
android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android23-clang --version

---
name: konata-release-workflow
description: >-
  Konata v3 在 Windows x64（绿色便携包）与 Android ARM64（正式签名 APK）上的安全构建、体积校验、
  APK 证书指纹核验与 release/ 交付工作流。仅在用户明确要求打包、签名、校验或清理发布产物时激活。
---

# Konata v3 双端发布与交付工作流

仅在用户明确指令构建或发布时执行本流程，严禁擅自运行发布打包或清理 `release/` 下既有产物。

## 1. 构建前全量门禁

1. 在仓库根目录执行 `dart run tool/verify.dart all` 与 `pwsh -NoProfile -File scripts/check_comments.ps1`，确保 0 错误、0 警告、0 注释违规。
2. 核验 `dart run tool/fetch_native.dart`：确认 `native/konata-native` 双端运行时文件完整且 SHA-256 与清单一致。
3. 核验体积红线：不额外打入多余字体包、测试视频、着色器大包或离线大库；Android 必须使用 `-t lib/main_android.dart --target-platform android-arm64 --split-per-abi`，严禁混入桌面依赖。

## 2. Windows x64 绿色便携构建

1. 在 `apps/konata` 目录执行：
   ```powershell
   flutter build windows --release
   ```
2. 检查 `apps/konata/build/windows/x64/runner/Release/`：
   - 核验必备动态库（`libmpv-2.dll`、`flutter_windows.dll`、`sqlite3` 等）与 `THIRD_PARTY_NOTICES` / `LICENSE`；
   - 归档到根目录 `release/` 时**仅打包编译产物与开源许可**，严禁把本机 `userdata/`、`cache/`、`photos/` 或密钥文件打进压缩包。

## 3. Android ARM64 正式签名构建

1. 正式包名为 `com.anime.konata`，发布密钥固定位于本机用户目录 `~/.konata/konata-release.p12`（别名 `konata`），严禁硬编码、记录或回显密码。
2. 在密钥持有者的交互式终端中运行：
   ```powershell
   pwsh -NoProfile -File .\tool\build_signed_android.ps1
   ```
3. 脚本会自动校验 `apksigner verify --print-certs`（SHA-256 证书指纹匹配）与 `aapt dump badging`（包名 `com.anime.konata` 与单调递增 `versionCode`）。

## 4. `release/` 原子交付与数据保护

1. 仅当 Windows 与 Android 双端产物全部构建并校验通过后，才原子更新 `release/latest-build.json` 并清理被替代的旧产物。
2. 清理 `release/` 下旧便携目录前，必须先检查内部是否存在用户运行产生的 `userdata/`、`cache/` 或 `photos/`；一旦存在用户数据必须保留并向用户汇报，绝不递归删除。

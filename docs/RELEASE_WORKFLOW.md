# 本地发布产物

Windows 和 Android 均成功构建，并完成 Windows 目录内容检查与 APK 签名验证后，`release/` 只保留最新同一轮的 Windows 便携目录、ZIP、Android APK 和 `latest-build.json`。新版未验证完或任一端构建失败时，不清理上一组可用产物。

清理只针对 `release/` 内明确属于旧版本的 CCPlayer 发布目录/ZIP/APK。先解析并核对绝对路径及最新清单，保留当前一组；保留其他文件，不清理应用数据或用户媒体。不跨 shell 拼接删除命令。正在运行导致目录占用时，如实报告，不能关闭用户进程来强行删除。

当前源码后续改动不会自动替换已交付安装包；用户明确要求构建后，再构建和清理。

## GitHub 首发 APK 的签名

Konata 公开版应用 ID 为 `com.anime.konata`，可与旧调试签名应用 `com.clainst.ccplayer` 并存。两者各有独立的媒体库、偏好和凭据。迁移验收前保留旧应用及数据。后续公开版更新需要同一签名及递增的版本号。

首次签名时，由密钥持有人在本机 PowerShell 中运行以下命令。使用 JDK 的 keytool，按提示设置密码。若已有此文件，跳过生成步骤，避免更换签名身份。

```powershell
$keyDir = Join-Path $env:USERPROFILE '.ccplayer'
$store = Join-Path $keyDir 'ccplayer-release.p12'
New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
if (Test-Path -LiteralPath $store) { throw '签名文件已存在，请核对已有密钥。' }
$keytool = 'D:\Codex-Projects\Anime\.jdk-cache\jdk-17\jdk-17.0.20.1+1\bin\keytool.exe'
& $keytool -genkeypair -keystore $store -storetype PKCS12 -alias ccplayer -keyalg RSA -keysize 3072 -validity 10000
```

将密钥文件做加密离线备份，密码单独保管。用 `keytool -list -v -keystore <密钥路径> -alias ccplayer` 查看并保存公开证书的 SHA-256 指纹。日常构建时，从项目根目录的 PowerShell 执行以下脚本，按提示输入密码：
 
```powershell
pwsh -NoProfile -File .\tool\build_signed_android.ps1
```

脚本从本机 Android 项目配置定位 Flutter 和 Android SDK，先核对密钥别名，再构建 ARM64 APK，并将 APK 的证书与本次密钥导出的公开证书比较。退出构建时清除本进程的密码环境变量。
验收时对生成的 APK 运行 Android Build Tools 的 `apksigner verify --verbose --print-certs`，将证书 SHA-256 与离线保存的指纹比较；用 `aapt dump badging` 核对 ID、版本和 ARM64。Debug、隔离验证和 Profile 包分别使用 `.debug`、`.validation`、`.profile` 后缀。签名私钥及密码只由持有人保管。[Android 应用签名文档](https://developer.android.com/studio/publish/app-signing)

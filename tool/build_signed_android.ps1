# 仅在签名密钥持有者的交互式 PowerShell 会话中运行。
param(
    [ValidateRange(0, 2147483647)] [int] $BuildNumber = 0,
    [string] $BuildName = '1.0.0',
    [string] $FanartRelayBase = ''
)
$ErrorActionPreference = 'Stop'
if ($env:KONATA_RELEASE_VALIDATION -eq '1') {
    throw '请退出独立验收构建环境，再执行正式签名。'
}

$Host.UI.RawUI.WindowTitle = 'Konata v3 Android 正式签名'
$repoRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $repoRoot 'apps/konata'
$localPropsPath = Join-Path $appDir 'android/local.properties'
if (!(Test-Path -LiteralPath $localPropsPath -PathType Leaf)) {
    throw "找不到 Android 本机配置：$localPropsPath"
}

$local = Get-Content -Raw -Encoding UTF8 -LiteralPath $localPropsPath | ConvertFrom-StringData
$flutter = Join-Path ($local['flutter.sdk'] -replace '\\\\', '\') 'bin/flutter.bat'
$env:ANDROID_HOME = $local['sdk.dir'] -replace '\\\\', '\'

$jdk = $env:JAVA_HOME
if (-not $jdk) {
    $localJdk = Join-Path (Split-Path -Parent ($local['flutter.sdk'] -replace '\\\\', '\')) '../.jdk-cache/jdk-17'
    $jdkFolder = Get-ChildItem -Directory -LiteralPath $localJdk -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin/keytool.exe') } |
        Select-Object -First 1
    if ($jdkFolder) { $jdk = $jdkFolder.FullName }
}
if ($jdk) { $env:JAVA_HOME = $jdk }
$keytool = if ($jdk) { Join-Path $jdk 'bin/keytool.exe' } else { 'keytool.exe' }

$store = Join-Path $env:USERPROFILE '.konata/konata-release.p12'
$keyAlias = 'konata'
if (!(Test-Path -LiteralPath $store -PathType Leaf)) { throw "找不到发布密钥 $store" }

$statusDir = Join-Path $appDir 'build'
$null = New-Item -ItemType Directory -Force -Path $statusDir
$statusFile = Join-Path $statusDir 'android-signing-status.txt'
$latestBuildPath = Join-Path $repoRoot 'release/latest-build.json'
$previous = if (Test-Path -LiteralPath $latestBuildPath -PathType Leaf) {
    Get-Content -LiteralPath $latestBuildPath -Raw | ConvertFrom-Json
} else {
    $null
}

if ($BuildNumber -eq 0) {
    if ($null -ne $previous) {
        $BuildNumber = [Math]::Max(2007, [int]$previous.androidVersionCode - 2000 + 1)
    } else {
        $BuildNumber = 2007
    }
}
# Flutter 分 ABI 打包 ARM64 APK 时会自动在构建号上叠加 ABI 偏移量 2000。
$expectedVersionCode = $BuildNumber + 2000
if ($null -ne $previous -and $expectedVersionCode -le [int]$previous.androidVersionCode) {
    throw "新版 APK 版本号 $expectedVersionCode 必须大于现有版本 $($previous.androidVersionCode)。"
}

function Set-BuildStage([string]$stage) {
    Set-Content -LiteralPath $statusFile -Encoding utf8 -Value "$(Get-Date -Format o) $stage"
}

Set-BuildStage 'waiting-for-local-password'
$secret = Read-Host '请输入你的 Android 发布密钥密码，然后按回车' -AsSecureString
$certFile = [IO.Path]::GetTempFileName()
Push-Location $appDir
try {
    Set-BuildStage 'checking-certificate'
    $env:KONATA_SIGNING_PASSWORD = [Net.NetworkCredential]::new('', $secret).Password
    & $keytool -exportcert -keystore $store -alias $keyAlias -storepass:env KONATA_SIGNING_PASSWORD -file $certFile
    if ($LASTEXITCODE) { throw "无法打开密钥，请核对密码和别名 $keyAlias。" }
    $fingerprint = (Get-FileHash -LiteralPath $certFile -Algorithm SHA256).Hash
    if ($null -ne $previous -and $fingerprint -ne $previous.androidCertificateSha256) {
        throw '密钥证书与现有发布版本不一致，已停止构建。'
    }

    Set-BuildStage 'building-release'
    $extraDefineArgs = @()
    if ($FanartRelayBase.Trim().Length -gt 0) {
        $extraDefineArgs += "--dart-define=KONATA_FANART_RELAY_BASE=$($FanartRelayBase.Trim())"
    }
    & $flutter build apk --release -t lib/main_android.dart --target-platform android-arm64 --split-per-abi --build-name=$BuildName --build-number=$BuildNumber @extraDefineArgs 2>&1 |
        Tee-Object -FilePath (Join-Path $statusDir 'android-release-build.log')
    if ($LASTEXITCODE) { throw 'Android Release 构建失败。' }

    $apk = Join-Path $appDir 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
    $buildTools = Get-ChildItem -Directory (Join-Path $env:ANDROID_HOME 'build-tools') |
        Where-Object { $_.Name -as [version] } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $signature = & (Join-Path $buildTools.FullName 'apksigner.bat') verify --print-certs $apk
    if ($LASTEXITCODE -or !($signature -match "^Signer #1 certificate SHA-256 digest: $fingerprint$")) {
        throw 'APK 证书与自持密钥不匹配。'
    }
    $badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apk
    if ($LASTEXITCODE -or !($badging -match "^package: name='com.anime.konata' versionCode='$expectedVersionCode'")) {
        throw 'APK 实际包名或版本号与预期不符。'
    }
    Write-Host "签名成功。证书 SHA-256 $fingerprint"
    Write-Host $apk
    Set-BuildStage 'signed-and-verified'
} catch {
    Set-BuildStage 'failed-see-signing-window'
    throw
} finally {
    Pop-Location
    Remove-Item Env:KONATA_SIGNING_PASSWORD -ErrorAction SilentlyContinue
    $secret.Dispose()
    Remove-Item -LiteralPath $certFile -ErrorAction SilentlyContinue
}

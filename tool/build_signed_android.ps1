# Run in the key holder's own interactive PowerShell session.
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Konata Android 正式签名'
$project = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $project
$local = Get-Content -Raw -Encoding UTF8 android/local.properties | ConvertFrom-StringData
$flutter = Join-Path $local['flutter.sdk'] 'bin/flutter.bat'
$env:ANDROID_HOME = $local['sdk.dir']
$jdk = $env:JAVA_HOME
if (-not $jdk) {
    $localJdk = Join-Path (Split-Path -Parent $local['flutter.sdk']) '../.jdk-cache/jdk-17'
    $jdkFolder = Get-ChildItem -Directory -LiteralPath $localJdk -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin/keytool.exe') } |
        Select-Object -First 1
    if ($jdkFolder) { $jdk = $jdkFolder.FullName }
}
if ($jdk) { $env:JAVA_HOME = $jdk }
$keytool = if ($jdk) { Join-Path $jdk 'bin/keytool.exe' } else { 'keytool.exe' }
$store = Join-Path $env:USERPROFILE '.ccplayer/ccplayer-release.p12'
if (!(Test-Path -LiteralPath $store -PathType Leaf)) { throw "找不到发布密钥 $store" }
$statusDir = Join-Path $project 'build'
$null = New-Item -ItemType Directory -Force -Path $statusDir
$statusFile = Join-Path $statusDir 'android-signing-status.txt'
function Set-BuildStage([string]$stage) {
    Set-Content -LiteralPath $statusFile -Encoding utf8 -Value "$(Get-Date -Format o) $stage"
}
Set-BuildStage 'waiting-for-local-password'
$secret = Read-Host '请输入你的 Android 发布密钥密码，然后按回车' -AsSecureString
$certFile = [IO.Path]::GetTempFileName()
try {
    Set-BuildStage 'checking-certificate'
    $env:CCPLAYER_SIGNING_PASSWORD = [Net.NetworkCredential]::new('', $secret).Password
    & $keytool -exportcert -keystore $store -alias ccplayer -storepass:env CCPLAYER_SIGNING_PASSWORD -file $certFile
    if ($LASTEXITCODE) { throw '无法打开密钥，请核对密码和别名 ccplayer。' }
    $fingerprint = (Get-FileHash -LiteralPath $certFile -Algorithm SHA256).Hash
    Set-BuildStage 'building-release'
    # Regenerate the Release plugin registrant after flutter test or pub get.
    & $flutter build apk --release --target-platform android-arm64 --split-per-abi 2>&1 |
        Tee-Object -FilePath (Join-Path $statusDir 'android-release-build.log')
    if ($LASTEXITCODE) { throw 'Android Release 构建失败。' }
    $apk = Join-Path $project 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
    $buildTools = Get-ChildItem -Directory (Join-Path $env:ANDROID_HOME 'build-tools') |
        Where-Object { $_.Name -as [version] } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $signature = & (Join-Path $buildTools.FullName 'apksigner.bat') verify --print-certs $apk
    if ($LASTEXITCODE -or !($signature -match "^Signer #1 certificate SHA-256 digest: $fingerprint$")) {
        throw 'APK 证书与自持密钥不匹配。'
    }
    Write-Host "签名成功。证书 SHA-256 $fingerprint"
    Write-Host $apk
    Set-BuildStage 'signed-and-verified'
} catch {
    Set-BuildStage 'failed-see-signing-window'
    throw
} finally {
    Remove-Item Env:CCPLAYER_SIGNING_PASSWORD -ErrorAction SilentlyContinue
    $secret.Dispose()
    Remove-Item -LiteralPath $certFile
}

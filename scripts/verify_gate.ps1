param(
    [ValidateSet('Baseline', 'Module', 'Full', 'Playback', 'WorkloadWindows', 'AndroidRuntime')][string]$Mode = 'Module',
    [string]$StageTag = 'work',
    [switch]$RunWorkload
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding($false)
$evidence = Join-Path $root '.agent-work/benchmarks'
[System.IO.Directory]::CreateDirectory($evidence) | Out-Null
if ($StageTag -notmatch '^[a-zA-Z0-9_-]+$') { throw '阶段标记包含非法字符' }

# 所有外部命令均显式检查退出码，任一步骤失败即阻断。
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "验证失败：$Program $($Arguments -join ' ')，退出码 $LASTEXITCODE" }
}

try {
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'guard')
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'analyze')
    Invoke-Checked 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/check_comments.ps1')
    if ($Mode -eq 'WorkloadWindows') {
        Invoke-Checked 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/workload_hook.ps1', '-StageTag', $StageTag, '-WindowsOnly')
        exit 0
    }
    if ($Mode -eq 'AndroidRuntime') {
        $serial = $env:KONATA_ANDROID_AUDIT_DEVICE
        if ([string]::IsNullOrWhiteSpace($serial)) { throw '缺少独立真机验收设备序列号' }
        $adb = Join-Path 'D:\AndroidSDK' 'platform-tools/adb.exe'
        $package = 'com.anime.konata.android_audit.validation'
        $existing = @(& $adb -s $serial shell pm list packages $package)
        if ($LASTEXITCODE -ne 0) { throw 'Android 设备探测失败' }
        if ($existing -contains "package:$package") { throw '独立测试包已存在，禁止覆盖' }
        # Flutter 工具在安装失败后可能尝试卸载默认调试包；若设备已有该包，直接阻断验收。
        $defaultDebug = @(& $adb -s $serial shell pm list packages com.anime.konata.debug)
        if ($LASTEXITCODE -ne 0 -or $defaultDebug -contains 'package:com.anime.konata.debug') { throw '设备已有正式调试包或无法确认隔离，禁止运行自动安装工具' }
        $mappings = @(& $adb -s $serial reverse --list)
        if ($LASTEXITCODE -ne 0 -or ($mappings -match 'tcp:48763')) { throw '隔离回环端口不可用' }
        Invoke-Checked $adb @('-s', $serial, 'reverse', 'tcp:48763', 'tcp:48763')
        $previousIsolated = $env:KONATA_ISOLATED_VALIDATION
        $env:KONATA_ISOLATED_VALIDATION = '1'
        Push-Location (Join-Path $root 'apps/konata')
        try {
            Invoke-Checked 'flutter' @('test','integration_test/android_playback_runtime_test.dart','-d',$serial,'--dart-define=KONATA_LANE=android_audit','--dart-define=KONATA_ANDROID_AUDIT_URL=http://127.0.0.1:48763')
        } finally {
            Pop-Location
            $env:KONATA_ISOLATED_VALIDATION = $previousIsolated
            & $adb -s $serial reverse --remove tcp:48763
            $installed = @(& $adb -s $serial shell pm list packages $package)
            if ($installed -contains "package:$package") {
                & $adb -s $serial uninstall $package
            }
        }
        exit 0
    }
    if ($Mode -eq 'Playback') {
        $fixture = $env:KONATA_PLAYBACK_FIXTURE
        if ([string]::IsNullOrWhiteSpace($fixture) -or !(Test-Path -LiteralPath $fixture -PathType Container)) {
            throw '需要通过 KONATA_PLAYBACK_FIXTURE 指定独立合成媒体目录'
        }
        Push-Location (Join-Path $root 'apps/konata')
        try {
            $pipeline = if ([string]::IsNullOrWhiteSpace($env:KONATA_PLAYBACK_PIPELINE)) { 'texture_fallback' } else { $env:KONATA_PLAYBACK_PIPELINE }
            if ($pipeline -notin @('texture_fallback','comp_10bit','comp_fp16','gpu_next')) { throw '未知测试渲染后端' }
            $integrationTest = if ($env:KONATA_DETAIL_AUDIT -eq 'true') { 'integration_test/detail_runtime_test.dart' } else { 'integration_test/playback_runtime_test.dart' }
            Invoke-Checked 'flutter' @('test', $integrationTest, '-d', 'windows', "--dart-define=KONATA_PLAYBACK_FIXTURE=$fixture", "--dart-define=KONATA_PLAYBACK_PIPELINE=$pipeline", "--dart-define=KONATA_PLAYBACK_EXPECT_HDR=$(([string]($env:KONATA_PLAYBACK_EXPECT_HDR -eq 'true')).ToLowerInvariant())", "--dart-define=KONATA_PLAYBACK_CAPTURE_SCRIPT=$env:KONATA_PLAYBACK_CAPTURE_SCRIPT", "--dart-define=KONATA_PLAYBACK_DOCK_SCRIPT=$env:KONATA_PLAYBACK_DOCK_SCRIPT", "--dart-define=KONATA_PLAYBACK_WEBDAV=$(([string]($env:KONATA_PLAYBACK_WEBDAV -eq 'true')).ToLowerInvariant())")
        } finally {
            Pop-Location
        }
        exit 0
    }
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'test')
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'build')

    if ($RunWorkload -or $Mode -eq 'Baseline' -or $Mode -eq 'Full') {
        Invoke-Checked 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/workload_hook.ps1', '-StageTag', $StageTag)
        $latest = Join-Path $evidence 'latest.log'
        if (!(Test-Path -LiteralPath $latest)) { throw '缺少实机采样结果' }
        if ($Mode -eq 'Baseline') {
            $baseline = Join-Path $evidence 'baseline.md'
            if (Test-Path -LiteralPath $baseline) { throw '初始基线已存在，禁止覆盖' }
            [System.IO.File]::WriteAllText($baseline, [System.IO.File]::ReadAllText($latest), $utf8)
        }
    }
} catch {
    [Console]::Error.WriteLine($_)
    exit 1
}

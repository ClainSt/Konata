param(
    [string]$StageTag = 'probe',
    [switch]$WindowsOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$appRoot = Join-Path $root 'apps/konata'
if ($StageTag -notmatch '^[a-zA-Z0-9_-]+$') { throw '阶段标记包含非法字符' }

$directory = Join-Path $root '.agent-work/benchmarks'
[System.IO.Directory]::CreateDirectory($directory) | Out-Null

$devicesToRun = New-Object System.Collections.Generic.List[string]
$devicesToRun.Add('windows')

if (-not $WindowsOnly) {
    $localPropsPath = Join-Path $appRoot 'android/local.properties'
    if (-not (Test-Path -LiteralPath $localPropsPath)) {
        throw "缺少 Android 工具链配置：$localPropsPath"
    }
    $properties = [System.IO.File]::ReadAllLines($localPropsPath)
    $sdkLine = @($properties | Where-Object { $_.StartsWith('sdk.dir=') })
    if ($sdkLine.Count -ne 1) { throw '无法确定 Android SDK 路径' }
    $sdk = $sdkLine[0].Substring(8).Replace('\\', '\')
    $adb = Join-Path $sdk 'platform-tools/adb.exe'
    $devices = @(& $adb devices)
    if ($LASTEXITCODE -ne 0) { throw 'ADB 设备探测失败' }
    $serials = @($devices | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($serials.Count -lt 1) { throw '未检测到已授权在线的 Android 设备（仅测桌面请加 -WindowsOnly）' }
    foreach ($serial in $serials) {
        $devicesToRun.Add($serial)
    }
}

$previousOutput = $env:KONATA_BENCHMARK_OUTPUT
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('| 设备 | 耗时中位数（微秒） | 处理器时间中位数（微秒） | 观测内存峰值中位数（字节） |')
$summary.Add('| --- | ---: | ---: | ---: |')

Push-Location $appRoot
try {
    foreach ($device in $devicesToRun) {
        $output = Join-Path $directory "$StageTag-$device.json"
        if (Test-Path -LiteralPath $output) { throw "实测证据已存在，禁止覆盖：$output" }
        $env:KONATA_BENCHMARK_OUTPUT = $output
        & flutter drive --profile --keep-app-running --driver=test_driver/runtime_workload.dart --target=integration_test/runtime_workload_test.dart -d $device
        if ($LASTEXITCODE -ne 0) { throw "设备负载压测失败：$device" }
        if (!(Test-Path -LiteralPath $output)) { throw "设备未回传压测证据：$device" }
        $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $output | ConvertFrom-Json
        if ($result.samples.Count -ne 5) { throw '设备采样轮数不足 5 轮' }
        foreach ($sample in $result.samples) {
            if ($sample.frame_count -le 0 -or $sample.build_us.Count -ne $sample.frame_count -or $sample.raster_us.Count -ne $sample.frame_count) {
                throw '渲染采样缺失或帧数不一致'
            }
            if (!$sample.PSObject.Properties['cpu_us']) {
                throw '处理器采集尚未接通，禁止认定为正式基线'
            }
        }
        $elapsed = @($result.samples.elapsed_us | Sort-Object)[2]
        $cpu = @($result.samples.cpu_us | Sort-Object)[2]
        $rss = @($result.samples.observed_peak_rss_bytes | Sort-Object)[2]
        $summary.Add("| $device | $elapsed | $cpu | $rss |")
    }
    [System.IO.File]::WriteAllLines((Join-Path $directory 'latest.log'), $summary, (New-Object System.Text.UTF8Encoding($false)))
} finally {
    $env:KONATA_BENCHMARK_OUTPUT = $previousOutput
    Pop-Location
}

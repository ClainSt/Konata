param([string]$StageTag = 'probe')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location (Split-Path $PSScriptRoot -Parent)
if ($StageTag -notmatch '^[a-zA-Z0-9_-]+$') { throw '阶段标记包含非法字符' }
$root = (Get-Location).Path
$directory = Join-Path $root '.agent-work/benchmarks'
[System.IO.Directory]::CreateDirectory($directory) | Out-Null
$properties = [System.IO.File]::ReadAllLines((Join-Path $root 'android/local.properties'))
$sdkLine = @($properties | Where-Object { $_.StartsWith('sdk.dir=') })
if ($sdkLine.Count -ne 1) { throw '无法确定设备工具链路径' }
$sdk = $sdkLine[0].Substring(8).Replace('\\', '\')
$adb = Join-Path $sdk 'platform-tools/adb.exe'
$devices = @(& $adb devices)
if ($LASTEXITCODE -ne 0) { throw '设备探测失败' }
$serials = @($devices | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if ($serials.Count -ne 2) { throw '需要两台已授权且在线的安卓设备' }
$previousOutput = $env:KONATA_BENCHMARK_OUTPUT
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('| 设备 | 耗时中位数（微秒） | 处理器时间中位数（微秒） | 观测内存峰值中位数（字节） |')
$summary.Add('| --- | ---: | ---: | ---: |')
try {
    foreach ($device in @('windows') + $serials) {
        $output = Join-Path $directory "$StageTag-$device.json"
        if (Test-Path $output) { throw "实测证据已存在，禁止覆盖：$output" }
        $env:KONATA_BENCHMARK_OUTPUT = $output
        & flutter drive --profile --keep-app-running --driver=test_driver/runtime_workload.dart --target=integration_test/runtime_workload_test.dart -d $device
        if ($LASTEXITCODE -ne 0) { throw "设备负载失败：$device" }
        if (!(Test-Path $output)) { throw "设备未回传证据：$device" }
        $result = Get-Content -Raw -Encoding UTF8 $output | ConvertFrom-Json
        if ($result.samples.Count -ne 5) { throw '设备采样轮数不足' }
        foreach ($sample in $result.samples) {
            if ($sample.frame_count -le 0 -or $sample.build_us.Count -ne $sample.frame_count -or $sample.raster_us.Count -ne $sample.frame_count) {
                throw '渲染采样缺失或帧数不一致'
            }
            if (!$sample.PSObject.Properties['cpu_us']) {
                throw '处理器采集尚未接通，禁止将不完整数据认定为正式基线'
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
}

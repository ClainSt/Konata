param(
    [ValidateSet('Baseline', 'Module', 'Full')][string]$Mode = 'Module',
    [string]$StageTag = 'work',
    [string]$TargetPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding($false)
$evidence = Join-Path $root '.agent-work/benchmarks'
[System.IO.Directory]::CreateDirectory($evidence) | Out-Null
if ($StageTag -notmatch '^[a-zA-Z0-9_-]+$') { throw '阶段标记包含非法字符' }

# 所有外部命令必须显式核验退出码，任何失败均阻断后续步骤。
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "验证失败：$Program，退出码 $LASTEXITCODE" }
}

try {
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'analyze')
    Invoke-Checked 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/check_comments.ps1')
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'test')
    Invoke-Checked 'dart' @('run', 'tool/verify.dart', 'build')
    Invoke-Checked 'pwsh' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/workload_hook.ps1', '-StageTag', $StageTag)
    $latest = Join-Path $evidence 'latest.log'
    if (!(Test-Path $latest)) { throw '缺少实机采样结果' }
    if ($Mode -eq 'Baseline') {
        $baseline = Join-Path $evidence 'baseline.md'
        if (Test-Path $baseline) { throw '初始基线已存在，禁止覆盖' }
        [System.IO.File]::WriteAllText($baseline, [System.IO.File]::ReadAllText($latest), $utf8)
    }
} catch {
    [Console]::Error.WriteLine($_)
    exit 1
}

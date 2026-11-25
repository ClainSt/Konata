# Konata v3 Windows 绿色便携 Release 构建脚本（自动剥离 Dart 调试符号至仓外目录）。
param(
    [string] $FanartRelayBase = ''
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $repoRoot 'apps/konata'
$symbolsDir = Join-Path $repoRoot 'build/symbols/windows'
$null = New-Item -ItemType Directory -Force -Path $symbolsDir

$extraDefineArgs = @()
if ($FanartRelayBase.Trim().Length -gt 0) {
    $extraDefineArgs += "--dart-define=KONATA_FANART_RELAY_BASE=$($FanartRelayBase.Trim())"
}

Push-Location $appDir
try {
    & flutter build windows --release --split-debug-info=$symbolsDir @extraDefineArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Windows Release 构建失败，退出码：$LASTEXITCODE"
    }
} finally {
    Pop-Location
}

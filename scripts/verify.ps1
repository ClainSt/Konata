# 统一委托 PowerShell 7 执行全量验证门禁。
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify_gate.ps1') @args
exit $LASTEXITCODE

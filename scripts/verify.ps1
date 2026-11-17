& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_gate.ps1") @args
exit $LASTEXITCODE

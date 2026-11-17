$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$violations = New-Object System.Collections.Generic.List[string]
# 扫描受版本控制的源码及新增测试，仅精确豁免 Flutter SDK 每次自动覆写的平台插件注册表与临时构建目录。
$ExcludeFiles = '(^|[\\/])(generated_plugin_registrant\.(cc|h|dart|m|swift)|GeneratedPluginRegistrant\.java)$'
$ExcludeDirs = '[\\/]flutter[\\/]ephemeral[\\/]'
$files = @(& git ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw '无法枚举源码' }
foreach ($file in $files) {
    if ($file -notmatch '\.(dart|cpp|cc|h|hpp|kt|java|ps1|py|swift|kts)$') { continue }
    if ($file -match $ExcludeFiles -or $file -match $ExcludeDirs) { continue }
    $lineNumber = 0
    $inBlock = $false
    $hashComments = $file -match '\.(ps1|py)$'
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path (Get-Location) $file))) {
        $lineNumber++
        $text = $line.Trim()
        if ($text.StartsWith('/*')) { $inBlock = $true }
        if ($text -match '^(//+|/\*|\*)' -or ($hashComments -and $text.StartsWith('#')) -or $inBlock) {
            $body = $text -replace '^(//+|#+|/\*+|\*+)\s*', ''
            $explanation = $body -replace '`[^`]*`', ''
            if ($body -match '(?i)^\s*(TODO|FIXME|HACK|XXX)\b|修改记录|变更记录|优化后写法|此处已优化|@author|@since|\b20\d{2}[-/]\d{1,2}[-/]\d{1,2}\b') {
                $violations.Add("${file}:${lineNumber}: 历史记录或待办注释")
            } elseif ($explanation -match '[a-zA-Z]{3,}' -and $explanation -notmatch '[\p{IsCJKUnifiedIdeographs}]') {
                $violations.Add("${file}:${lineNumber}: 缺少中文功能解释")
            }
            if ($body -match '^(if|for|while|return|class|void|final|const)\s*[\s(\w].*[;{}]$') {
                $violations.Add("${file}:${lineNumber}: 疑似注释死代码")
            }
        }
        if ($text.Contains('*/')) { $inBlock = $false }
    }
}
if ($violations.Count -gt 0) {
    $logDirectory = Join-Path (Get-Location) '.agent-work/benchmarks'
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    [System.IO.File]::WriteAllLines((Join-Path $logDirectory 'comment_violations.log'), $violations, (New-Object System.Text.UTF8Encoding($false)))
    $violations | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 1
}
Write-Output '源码注释检查通过'

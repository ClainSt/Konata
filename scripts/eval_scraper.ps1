# Konata 零落盘密钥与本地 CD2 目录只读刮削评测启动器（Windows）。
# 所有评测资产严格隔离在 .gitignore 忽略的 local_eval/ 目录下，绝不进入仓库或发布产物。
param(
    [ValidateSet('ParseOnly', 'InitGolden', 'Golden', 'OnlyFailed', 'AcceptBaseline')]
    [string]$Mode = 'Golden',

    [switch]$RefreshSnapshot,

    [string]$MediaRoot = '',

    [string]$ImportListing = '',

    [string]$SubPath = '',

    [ValidateSet('auto', 'off', 'batch', 'full')]
    [string]$Artwork = 'auto',

    [ValidateSet('webdav', 'local')]
    [string]$SourceKind = 'webdav',

    [ValidateSet('none', 'all', '404', 'tmdb', 'bgm', 'fanart')]
    [string]$RefreshCache = 'none',

    [switch]$AllowFanartRelay,

    [switch]$Offline,

    [switch]$WithExplicit,

    [switch]$PromptKeys,

    [switch]$Force,

    [string]$Only = '',

    [ValidateRange(1, 5)]
    [int]$Workers = 4,

    [ValidateRange(20, 1000)]
    [int]$SampleSize = 180,

    [string]$Proxy = '',

    [switch]$NoProxy,

    [string]$EvalDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
Set-Location -LiteralPath $repoRoot

$resolvedEvalDir = if ([string]::IsNullOrWhiteSpace($EvalDir)) {
    Join-Path $repoRoot 'local_eval'
} else {
    $EvalDir
}
$manifestPath = Join-Path $resolvedEvalDir 'corpus_manifest.tsv'
$metaPath = Join-Path $resolvedEvalDir 'corpus_meta.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# 与 lib/domain/models/media_extensions.dart 保持一致的媒体与本地封面扩展名及忽略目录唯一常量。
$script:AllowedEvalExts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in @(
    '.mkv', '.mp4', '.m2ts', '.ts', '.avi', '.webm', '.mov', '.m4v',
    '.flv', '.wmv', '.mpg', '.mpeg', '.vob', '.ogm', '.rmvb', '.iso',
    '.cue', '.flac', '.wav', '.alac', '.m4a', '.aac', '.opus', '.ogg',
    '.mp3', '.ac3', '.eac3', '.ec3', '.dts', '.dtshd', '.thd', '.ape',
    '.tak', '.tta', '.wv', '.dsf', '.dff', '.aiff', '.aif', '.mka',
    '.ass', '.ssa', '.srt', '.vtt', '.sup', '.idx', '.sub',
    '.jpg', '.jpeg', '.png', '.webp', '.bmp', '.avif'
)) { [void]$script:AllowedEvalExts.Add($ext) }

$script:IgnoredEvalDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($d in @(
    '@eadir', '$recycle.bin', 'system volume information',
    'fonts', 'font', '.git', '.@__thumb'
)) { [void]$script:IgnoredEvalDirs.Add($d) }

# 定位本机 Dart 工具链（依次检查 PATH、local.properties 与标准 SDK 目录）。
function Resolve-DartExecutable {
    $cmd = Get-Command 'dart' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $localProps = Join-Path $repoRoot 'android/local.properties'
    if (Test-Path -LiteralPath $localProps) {
        $sdkLine = @([System.IO.File]::ReadAllLines($localProps) | Where-Object { $_.StartsWith('flutter.sdk=') }) | Select-Object -First 1
        if ($sdkLine) {
            $sdkDir = $sdkLine.Substring(12).Replace('\\', '\').Trim()
            foreach ($rel in @('bin\dart.bat', 'bin\cache\dart-sdk\bin\dart.exe')) {
                $candidate = Join-Path $sdkDir $rel
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    }

    foreach ($fallback in @('D:\FlutterSDK\bin\dart.bat', 'D:\FlutterSDK\bin\cache\dart-sdk\bin\dart.exe')) {
        if (Test-Path -LiteralPath $fallback) { return $fallback }
    }
    throw '未找到可用的 Dart 可执行文件，请确认 Flutter SDK 已配置。'
}

# 读取 Windows 注册表系统代理（仅在未显式指定代理且未设置环境变量时兜底）。
function Resolve-EffectiveProxyUrl {
    if ($NoProxy) { return '' }
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) { return $Proxy.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY) -or -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) {
        return ''
    }
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($null -eq $reg -or $reg.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace($reg.ProxyServer)) {
            return ''
        }
        $raw = [string]$reg.ProxyServer
        if ($raw.Contains('=')) {
            foreach ($part in $raw.Split(';')) {
                $kv = $part.Trim()
                if ($kv -match '^(?i)https=(.+)$') { return "http://$($Matches[1].Trim())" }
                if ($kv -match '^(?i)http=(.+)$') { return "http://$($Matches[1].Trim())" }
                if ($kv -match '^(?i)socks=(.+)$') { return "socks5://$($Matches[1].Trim())" }
            }
            return ''
        }
        if ($raw -match '^[a-zA-Z]+://') { return $raw.Trim() }
        return "http://$($raw.Trim())"
    } catch {
        return ''
    }
}

# 对本地 CD2 挂载目录执行严格只读高速快照（仅枚举目录项名称与字节数，绝不打开任何文件）。
function Invoke-ReadOnlyCorpusSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [string]$RelativeSubPath = ''
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "媒体根目录不存在或无法访问：$RootPath"
    }
    $normRoot = (Resolve-Path -LiteralPath $RootPath).Path.TrimEnd('\', '/')
    $normSub = $RelativeSubPath.Trim().Replace('\', '/').Trim('/')
    $scanStartDir = if ([string]::IsNullOrEmpty($normSub)) {
        $normRoot
    } else {
        Join-Path $normRoot ($normSub.Replace('/', '\'))
    }
    if (-not (Test-Path -LiteralPath $scanStartDir -PathType Container)) {
        throw "局部扫描子目录不存在：$scanStartDir"
    }

    $allowedExts = $script:AllowedEvalExts
    $ignoredDirs = $script:IgnoredEvalDirs

    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($scanStartDir)

    $collected = [System.Collections.Generic.List[string]]::new()
    $dirCount = 0
    $errorDirs = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $retryDelaysMs = @(500, 1500)

    Write-Host "开始只读枚举目录快照（零文件内容读取、零 ffprobe）..." -ForegroundColor Cyan

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $dirCount++
        if ($dirCount % 200 -eq 0) {
            Write-Host ("已枚举 {0} 目录，收录 {1} 媒体文件，耗时 {2:N1}s..." -f $dirCount, $collected.Count, $stopwatch.Elapsed.TotalSeconds)
        }

        $entries = $null
        for ($attempt = 0; $attempt -le $retryDelaysMs.Count; $attempt++) {
            try {
                $dirInfo = [System.IO.DirectoryInfo]::new($current)
                $entries = @($dirInfo.EnumerateFileSystemInfos())
                break
            } catch {
                if ($attempt -ge $retryDelaysMs.Count) {
                    $errorDirs++
                    Write-Warning "跳过列举失败目录（已重试）：$($current.Substring($normRoot.Length).TrimStart('\', '/'))"
                    break
                }
                Start-Sleep -Milliseconds $retryDelaysMs[$attempt]
            }
        }
        if ($null -eq $entries) { continue }

        foreach ($entry in $entries) {
            $name = $entry.Name
            if ([string]::IsNullOrEmpty($name) -or $name.StartsWith('.')) { continue }
            $isReparse = ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparse) { continue }

            if ($entry -is [System.IO.DirectoryInfo]) {
                if (-not $ignoredDirs.Contains($name)) {
                    $queue.Enqueue($entry.FullName)
                }
                continue
            }

            if ($entry -is [System.IO.FileInfo]) {
                $ext = $entry.Extension
                if ([string]::IsNullOrEmpty($ext) -or (-not $allowedExts.Contains($ext))) {
                    continue
                }
                $relPath = $entry.FullName.Substring($normRoot.Length).TrimStart('\', '/').Replace('\', '/')
                $collected.Add("$relPath`t$($entry.Length)")
            }
        }
    }

    $stopwatch.Stop()
    [System.IO.Directory]::CreateDirectory($resolvedEvalDir) | Out-Null

    # 局部刷新模式：保留原有其他前缀，仅替换当前子目录前缀条目。
    $finalLines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($normSub) -and (Test-Path -LiteralPath $manifestPath)) {
        $prefix = "$normSub/"
        foreach ($oldLine in [System.IO.File]::ReadAllLines($manifestPath, $utf8NoBom)) {
            if ([string]::IsNullOrWhiteSpace($oldLine)) { continue }
            $tabIdx = $oldLine.LastIndexOf("`t")
            $oldRel = if ($tabIdx -ge 0) { $oldLine.Substring(0, $tabIdx) } else { $oldLine }
            if (-not ($oldRel -eq $normSub -or $oldRel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
                $finalLines.Add($oldLine)
            }
        }
    }
    foreach ($line in $collected) {
        $finalLines.Add($line)
    }
    $finalLines.Sort([System.StringComparer]::Ordinal)

    $tmpManifest = "$manifestPath.tmp.$PID"
    try {
        [System.IO.File]::WriteAllLines($tmpManifest, $finalLines, $utf8NoBom)
        if (Test-Path -LiteralPath $manifestPath) {
            Remove-Item -LiteralPath $manifestPath -Force
        }
        Move-Item -LiteralPath $tmpManifest -Destination $manifestPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmpManifest) {
            Remove-Item -LiteralPath $tmpManifest -Force -ErrorAction SilentlyContinue
        }
    }

    $metaObj = [ordered]@{
        updatedAt       = [DateTime]::UtcNow.ToString('o')
        incrementalSub  = $normSub
        scannedDirs     = $dirCount
        skippedErrorDir = $errorDirs
        totalFiles      = $finalLines.Count
        elapsedMs       = [int]$stopwatch.ElapsedMilliseconds
    }
    [System.IO.File]::WriteAllText($metaPath, ($metaObj | ConvertTo-Json -Depth 4), $utf8NoBom)

    Write-Host ("快照更新完成：共 {0} 媒体文件（本次枚举 {1} 目录，耗时 {2:N1}s），已写入 {3}" -f $finalLines.Count, $dirCount, $stopwatch.Elapsed.TotalSeconds, $manifestPath) -ForegroundColor Green
}

# 弹出置顶 WinForms 掩码密码框获取当次内存密钥（绝不落盘、绝不读取 dart_defines.dev.json）。
function Show-ZeroDiskKeyPrompt {
    param([string]$ReasonText = '需要联网回源，请临时粘贴当次评测所需密钥（绝不落盘）')

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Konata 评测零落盘密钥输入'
    $form.Size = [System.Drawing.Size]::new(540, 290)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.TopMost = $true

    $infoLabel = [System.Windows.Forms.Label]::new()
    $infoLabel.Text = "$ReasonText`r`n密钥仅注入当次子进程内存环境变量，评测结束立即销毁。"
    $infoLabel.Location = [System.Drawing.Point]::new(16, 12)
    $infoLabel.Size = [System.Drawing.Size]::new(500, 38)
    $form.Controls.Add($infoLabel)

    $lblTmdb = [System.Windows.Forms.Label]::new()
    $lblTmdb.Text = 'TMDB API Key / v4 Token（必填）：'
    $lblTmdb.Location = [System.Drawing.Point]::new(16, 58)
    $lblTmdb.Size = [System.Drawing.Size]::new(480, 20)
    $form.Controls.Add($lblTmdb)

    $txtTmdb = [System.Windows.Forms.TextBox]::new()
    $txtTmdb.Location = [System.Drawing.Point]::new(16, 80)
    $txtTmdb.Size = [System.Drawing.Size]::new(490, 24)
    $txtTmdb.UseSystemPasswordChar = $true
    $form.Controls.Add($txtTmdb)

    $lblFanartApi = [System.Windows.Forms.Label]::new()
    $lblFanartApi.Text = 'Fanart.tv Project API Key（选填，留空则不直连官方 Fanart）：'
    $lblFanartApi.Location = [System.Drawing.Point]::new(16, 112)
    $lblFanartApi.Size = [System.Drawing.Size]::new(480, 20)
    $form.Controls.Add($lblFanartApi)

    $txtFanartApi = [System.Windows.Forms.TextBox]::new()
    $txtFanartApi.Location = [System.Drawing.Point]::new(16, 134)
    $txtFanartApi.Size = [System.Drawing.Size]::new(490, 24)
    $txtFanartApi.UseSystemPasswordChar = $true
    $form.Controls.Add($txtFanartApi)

    $lblFanartClient = [System.Windows.Forms.Label]::new()
    $lblFanartClient.Text = 'Fanart.tv Personal Client Key（选填）：'
    $lblFanartClient.Location = [System.Drawing.Point]::new(16, 166)
    $lblFanartClient.Size = [System.Drawing.Size]::new(480, 20)
    $form.Controls.Add($lblFanartClient)

    $txtFanartClient = [System.Windows.Forms.TextBox]::new()
    $txtFanartClient.Location = [System.Drawing.Point]::new(16, 188)
    $txtFanartClient.Size = [System.Drawing.Size]::new(490, 24)
    $txtFanartClient.UseSystemPasswordChar = $true
    $form.Controls.Add($txtFanartClient)

    $btnOk = [System.Windows.Forms.Button]::new()
    $btnOk.Text = '确定并继续评测'
    $btnOk.Location = [System.Drawing.Point]::new(280, 222)
    $btnOk.Size = [System.Drawing.Size]::new(120, 30)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $btnOk
    $form.Controls.Add($btnOk)

    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = '取消'
    $btnCancel.Location = [System.Drawing.Point]::new(416, 222)
    $btnCancel.Size = [System.Drawing.Size]::new(90, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $btnCancel
    $form.Controls.Add($btnCancel)

    $form.Add_Shown({ $form.TopMost = $true; $form.BringToFront(); $form.Activate(); $txtTmdb.Focus() })

    try {
        $dialogResult = $form.ShowDialog()
        if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }
        return @{
            TmdbKey         = $txtTmdb.Text.Trim()
            FanartApiKey    = $txtFanartApi.Text.Trim()
            FanartClientKey = $txtFanartClient.Text.Trim()
        }
    } finally {
        $txtTmdb.Text = ''
        $txtFanartApi.Text = ''
        $txtFanartClient.Text = ''
        $form.Dispose()
    }
}

# 步骤 1：按需导入外部清单或刷新本地 CD2 目录快照。
if (-not [string]::IsNullOrWhiteSpace($ImportListing)) {
    if (-not (Test-Path -LiteralPath $ImportListing -PathType Leaf)) {
        throw "待导入的云盘清单文件不存在：$ImportListing"
    }
    $allowedExts = $script:AllowedEvalExts
    $ignoredDirs = $script:IgnoredEvalDirs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $imported = [System.Collections.Generic.List[string]]::new(260000)
    foreach ($raw in [System.IO.File]::ReadLines($ImportListing)) {
        $line = $raw.TrimEnd("`r", "`n")
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $tab = $line.LastIndexOf("`t")
        $fullPath = if ($tab -ge 0) { $line.Substring(0, $tab) } else { $line }
        $sizeStr = if ($tab -ge 0) { $line.Substring($tab + 1).Trim() } else { '0' }
        $rel = $fullPath.Replace('\', '/')
        if ($rel.Length -ge 3 -and $rel[1] -eq ':' -and $rel[2] -eq '/') {
            $rel = $rel.Substring(3)
        }
        $rel = $rel.TrimStart('/')
        if ([string]::IsNullOrEmpty($rel)) { continue }
        $segs = $rel.Split('/')
        $skip = $false
        for ($i = 0; $i -lt $segs.Length - 1; $i++) {
            if ($segs[$i].StartsWith('.') -or $ignoredDirs.Contains($segs[$i])) {
                $skip = $true
                break
            }
        }
        if ($skip) { continue }
        $fileName = $segs[$segs.Length - 1]
        if ($fileName.StartsWith('.')) { continue }
        $dot = $fileName.LastIndexOf('.')
        if ($dot -lt 0 -or (-not $allowedExts.Contains($fileName.Substring($dot)))) { continue }
        $imported.Add("$rel`t$sizeStr")
    }
    $imported.Sort([System.StringComparer]::Ordinal)
    [System.IO.Directory]::CreateDirectory($resolvedEvalDir) | Out-Null
    $tmpManifest = "$manifestPath.tmp.$PID"
    try {
        [System.IO.File]::WriteAllLines($tmpManifest, $imported, $utf8NoBom)
        if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
        Move-Item -LiteralPath $tmpManifest -Destination $manifestPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmpManifest) { Remove-Item -LiteralPath $tmpManifest -Force -ErrorAction SilentlyContinue }
    }
    $sw.Stop()
    $metaObj = [ordered]@{
        updatedAt       = [DateTime]::UtcNow.ToString('o')
        importedFrom    = $ImportListing
        totalFiles      = $imported.Count
        elapsedMs       = [int]$sw.ElapsedMilliseconds
    }
    [System.IO.File]::WriteAllText($metaPath, ($metaObj | ConvertTo-Json -Depth 4), $utf8NoBom)
    Write-Host ("清单导入完成：共 {0} 媒体文件（耗时 {1:N1}s），已写入 {2}" -f $imported.Count, $sw.Elapsed.TotalSeconds, $manifestPath) -ForegroundColor Green
} elseif ($RefreshSnapshot) {
    if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
        throw '使用 -RefreshSnapshot 时必须通过 -MediaRoot 指定本地 CD2 挂载根目录。'
    }
    Invoke-ReadOnlyCorpusSnapshot -RootPath $MediaRoot -RelativeSubPath $SubPath
    if ($Mode -eq 'ParseOnly' -and -not (Test-Path -LiteralPath $manifestPath)) {
        exit 1
    }
}

# 步骤 2：组装纯 Dart 评测命令行参数。
$dartExe = Resolve-DartExecutable
$modeArg = switch ($Mode) {
    'ParseOnly'      { '--mode=parse-only' }
    'InitGolden'     { '--mode=init-golden' }
    'Golden'         { '--mode=golden' }
    'OnlyFailed'     { '--mode=only-failed' }
    'AcceptBaseline' { '--mode=accept-baseline' }
}

$cliArgs = [System.Collections.Generic.List[string]]::new()
$cliArgs.Add('run')
$cliArgs.Add('tool/eval_scraper.dart')
$cliArgs.Add($modeArg)
$cliArgs.Add("--eval-dir=$resolvedEvalDir")
$cliArgs.Add("--artwork=$Artwork")
$cliArgs.Add("--source-kind=$SourceKind")
$cliArgs.Add("--refresh-cache=$RefreshCache")
$cliArgs.Add("--workers=$Workers")
$cliArgs.Add("--sample-size=$SampleSize")
if ($AllowFanartRelay) { $cliArgs.Add('--allow-fanart-relay') }
if ($Offline) { $cliArgs.Add('--offline') }
if ($WithExplicit) { $cliArgs.Add('--with-explicit') }
if ($Force) { $cliArgs.Add('--force') }
if (-not [string]::IsNullOrWhiteSpace($Only)) { $cliArgs.Add("--only=$Only") }

$effectiveProxy = Resolve-EffectiveProxyUrl
if ($NoProxy) {
    $cliArgs.Add('--no-proxy')
} elseif (-not [string]::IsNullOrWhiteSpace($effectiveProxy)) {
    $cliArgs.Add("--proxy=$effectiveProxy")
}

$isOnlineMode = ($Mode -eq 'Golden' -or $Mode -eq 'OnlyFailed')

# 步骤 3：仅在当次子进程内存注入密钥并在退出时彻底销毁。
$keys = $null
try {
    Remove-Item Env:KONATA_EVAL_TMDB_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:KONATA_EVAL_FANART_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:KONATA_EVAL_FANART_CLIENT_KEY -ErrorAction SilentlyContinue

    if ($isOnlineMode -and $PromptKeys -and (-not $Offline)) {
        $keys = Show-ZeroDiskKeyPrompt -ReasonText '已指定提前输入密钥，请粘贴当次评测所需凭据：'
        if ($null -eq $keys) {
            Write-Warning '用户已取消密钥输入，评测中止。'
            exit 130
        }
        if (-not [string]::IsNullOrEmpty($keys.TmdbKey)) { $env:KONATA_EVAL_TMDB_KEY = $keys.TmdbKey }
        if (-not [string]::IsNullOrEmpty($keys.FanartApiKey)) { $env:KONATA_EVAL_FANART_API_KEY = $keys.FanartApiKey }
        if (-not [string]::IsNullOrEmpty($keys.FanartClientKey)) { $env:KONATA_EVAL_FANART_CLIENT_KEY = $keys.FanartClientKey }
    }

    & $dartExe @cliArgs
    $code = $LASTEXITCODE

    # 按需延迟弹窗：仅当本地 VCR 缓存未命中且缺密钥（约定退出码 42）时弹窗一次并自动续跑。
    if ($code -eq 42 -and $isOnlineMode -and (-not $Offline) -and $null -eq $keys) {
        $keys = Show-ZeroDiskKeyPrompt -ReasonText '检测到有新增查询未命中本地 VCR 缓存，请临时输入密钥以继续回源：'
        if ($null -eq $keys -or [string]::IsNullOrWhiteSpace($keys.TmdbKey)) {
            Write-Warning '未提供 TMDB 密钥，已中止本次在线回源。'
            exit 130
        }
        $env:KONATA_EVAL_TMDB_KEY = $keys.TmdbKey
        if (-not [string]::IsNullOrEmpty($keys.FanartApiKey)) { $env:KONATA_EVAL_FANART_API_KEY = $keys.FanartApiKey }
        if (-not [string]::IsNullOrEmpty($keys.FanartClientKey)) { $env:KONATA_EVAL_FANART_CLIENT_KEY = $keys.FanartClientKey }

        & $dartExe @cliArgs
        $code = $LASTEXITCODE
    }

    exit $code
} finally {
    Remove-Item Env:KONATA_EVAL_TMDB_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:KONATA_EVAL_FANART_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:KONATA_EVAL_FANART_CLIENT_KEY -ErrorAction SilentlyContinue
    if ($null -ne $keys) {
        $keys.TmdbKey = ''
        $keys.FanartApiKey = ''
        $keys.FanartClientKey = ''
        $keys = $null
    }
}

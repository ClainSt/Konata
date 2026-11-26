param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('new', 'status', 'sync-env', 'cleanup', 'lock-verify')]
    [string]$Action,
    [string]$Name = '',
    [string]$Allow = '',
    [string]$Branch = '',
    [string]$Base = 'main',
    [switch]$Force,
    [ValidateSet('Baseline', 'Module', 'Full', 'Playback', 'WorkloadWindows', 'AndroidRuntime')]
    [string]$Mode = 'Module',
    [string]$StageTag = 'work',
    [int]$LockTimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 解析当前工作树路径与主仓库根目录，支持在任意 Worktree 内调用。
$currentWorktreeRoot = (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
$worktreeListLines = @(& git -C $currentWorktreeRoot worktree list --porcelain)
if ($LASTEXITCODE -ne 0 -or $worktreeListLines.Count -eq 0) {
    throw '无法读取 `git worktree` 列表，请确认当前处于有效 Git 仓库内'
}
$firstWorktreeLine = @($worktreeListLines | Where-Object { $_.StartsWith('worktree ') }) | Select-Object -First 1
if (-not $firstWorktreeLine) {
    throw '无法解析主仓库根目录'
}
$mainRepoRoot = (Resolve-Path $firstWorktreeLine.Substring(9).Trim()).Path
$projectsRoot = Split-Path $mainRepoRoot -Parent
$lanesRoot = Join-Path $projectsRoot 'Konata-lanes'
$hardwareLockPath = Join-Path $projectsRoot '.konata-hardware-gate.lock'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 定位可用于子进程的 PowerShell 7 执行器。
function Resolve-PowerShellHost {
    $pwshCmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($pwshCmd) { return $pwshCmd.Source }
    $psCmd = Get-Command 'powershell' -ErrorAction SilentlyContinue
    if ($psCmd) { return $psCmd.Source }
    throw '未找到可用的 PowerShell 执行器'
}

# 确保当前进程 PATH 包含同源 Flutter 工具链。
function Ensure-FlutterToolchainInPath([string]$RepoRoot) {
    if (Get-Command 'flutter' -ErrorAction SilentlyContinue) { return }
    $localProps = Join-Path $RepoRoot 'apps/konata/android/local.properties'
    if (Test-Path -LiteralPath $localProps) {
        $sdkLine = @([System.IO.File]::ReadAllLines($localProps) | Where-Object { $_.StartsWith('flutter.sdk=') }) | Select-Object -First 1
        if ($sdkLine) {
            $sdkDir = $sdkLine.Substring(12).Replace('\\', '\').Trim()
            $flutterBin = Join-Path $sdkDir 'bin'
            if (Test-Path -LiteralPath (Join-Path $flutterBin 'flutter.bat')) {
                $env:PATH = "$flutterBin;$env:PATH"
                return
            }
        }
    }
    if (Test-Path -LiteralPath 'D:\FlutterSDK\bin\flutter.bat') {
        $env:PATH = "D:\FlutterSDK\bin;$env:PATH"
        return
    }
    throw '未在环境变量或 `local.properties` 中找到 `flutter` 工具链'
}

# 将主仓未受版本控制的本地构建前置文件同步到目标车道工作树。
function Copy-UntrackedPrerequisites([string]$TargetWorktreeRoot) {
    $singleFiles = @(
        'apps/konata/android/local.properties',
        'dart_defines.dev.json'
    )
    foreach ($rel in $singleFiles) {
        $src = Join-Path $mainRepoRoot $rel
        $dst = Join-Path $TargetWorktreeRoot $rel
        if (Test-Path -LiteralPath $src) {
            $parent = Split-Path $dst -Parent
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }

    foreach ($platformSubdir in @('native/konata-native/windows', 'native/konata-native/android')) {
        $srcDir = Join-Path $mainRepoRoot $platformSubdir
        $dstDir = Join-Path $TargetWorktreeRoot $platformSubdir
        if ((Test-Path -LiteralPath $srcDir) -and -not (Test-Path -LiteralPath $dstDir)) {
            [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null
            & robocopy $srcDir $dstDir /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) {
                throw "复制原生缓存目录失败：$srcDir -> $dstDir"
            }
        }
    }
}

# 写入车道私有的写权限白名单文件（位于工作树独立 gitdir 内，永不入 Git）。
function Write-LaneWhitelist([string]$LanePath, [string]$LaneName, [string]$BranchName, [string]$BaseRef, [string[]]$AllowedPrefixes) {
    $rawGitDir = (& git -C $LanePath rev-parse --git-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rawGitDir)) {
        throw "无法解析车道私有 gitdir：$LanePath"
    }
    $gitDirPath = if ([System.IO.Path]::IsPathRooted($rawGitDir)) {
        $rawGitDir
    } else {
        Join-Path $LanePath $rawGitDir
    }
    $manifest = [ordered]@{
        lane      = $LaneName
        branch    = $BranchName
        base      = $BaseRef
        allow     = @($AllowedPrefixes)
        createdAt = (Get-Date -Format 'o')
    }
    $json = $manifest | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $gitDirPath 'konata-lane.json'), $json, $utf8NoBom)
}

# 创建一条短生命周期并行车道，自动配置分支、白名单、原生前置文件与依赖。
function Invoke-LaneNew {
    if ($Name -notmatch '^[a-z][a-z0-9_-]{0,31}$') {
        throw '参数 `-Name` 必须以小写字母开头，仅含小写字母、数字、连字符或下划线（最长 32 位）'
    }
    $allowedPrefixes = @($Allow -split ',' | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_.Length -gt 0 })
    if ($allowedPrefixes.Count -eq 0) {
        throw '创建车道必须通过 `-Allow` 指定至少一个授权修改路径前缀（如 `packages/engines/engine_scraping/`）'
    }

    $branchName = if ([string]::IsNullOrWhiteSpace($Branch)) { "lane/$Name" } else { $Branch.Trim() }
    [System.IO.Directory]::CreateDirectory($lanesRoot) | Out-Null
    $lanePath = Join-Path $lanesRoot $Name
    if (Test-Path -LiteralPath $lanePath) {
        throw "车道目录已存在，请更换名称或先执行 cleanup：$lanePath"
    }

    & git -C $mainRepoRoot show-ref --verify --quiet "refs/heads/$branchName"
    if ($LASTEXITCODE -eq 0) {
        & git -C $mainRepoRoot worktree add $lanePath $branchName
    } else {
        & git -C $mainRepoRoot worktree add -b $branchName $lanePath $Base
    }
    if ($LASTEXITCODE -ne 0) {
        throw "创建 Git Worktree 失败：$lanePath"
    }

    Write-LaneWhitelist -LanePath $lanePath -LaneName $Name -BranchName $branchName -BaseRef $Base -AllowedPrefixes $allowedPrefixes
    Copy-UntrackedPrerequisites -TargetWorktreeRoot $lanePath

    Ensure-FlutterToolchainInPath -RepoRoot $mainRepoRoot
    Push-Location $lanePath
    try {
        & flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "车道依赖解析失败：$lanePath"
        }
    } finally {
        Pop-Location
    }
    Write-Output "车道 [$Name] 创建完成：$lanePath（分支 $branchName，白名单：$($allowedPrefixes -join ', ')）"
}

# 列出主仓与所有活跃车道的分支、未提交文件数与白名单摘要。
function Invoke-LaneStatus {
    Write-Output '=== Konata v3 多工作树车道状态 ==='
    $paths = @($worktreeListLines | Where-Object { $_.StartsWith('worktree ') } | ForEach-Object { $_.Substring(9).Trim() })
    foreach ($wt in $paths) {
        $branchName = (& git -C $wt branch --show-current).Trim()
        if ([string]::IsNullOrWhiteSpace($branchName)) { $branchName = '(游离 HEAD)' }
        $dirtyCount = @(& git -C $wt status --porcelain).Count
        $lastCommit = (& git -C $wt log -1 --pretty=format:'%h %s' 2>$null)
        if (-not $lastCommit) { $lastCommit = '(尚无提交)' }
        $rawGitDir = (& git -C $wt rev-parse --git-dir).Trim()
        $gitDirPath = if ([System.IO.Path]::IsPathRooted($rawGitDir)) { $rawGitDir } else { Join-Path $wt $rawGitDir }
        $laneFile = Join-Path $gitDirPath 'konata-lane.json'
        $allowSummary = '全仓授权'
        if (Test-Path -LiteralPath $laneFile) {
            $meta = Get-Content -Raw -Encoding UTF8 -LiteralPath $laneFile | ConvertFrom-Json
            $allowSummary = ($meta.allow -join ', ')
        }
        Write-Output "$branchName | 未提交: $dirtyCount | 白名单: $allowSummary | $lastCommit | $wt"
    }
}

# 向单个或全部活跃车道同步未受版本控制的本机前置文件。
function Invoke-LaneSyncEnv {
    $targets = @()
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $targets += (Join-Path $lanesRoot $Name)
    } elseif (Test-Path -LiteralPath $lanesRoot) {
        $targets = @(Get-ChildItem -Directory -LiteralPath $lanesRoot | ForEach-Object { $_.FullName })
    }
    $count = 0
    foreach ($dir in $targets) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            Copy-UntrackedPrerequisites -TargetWorktreeRoot $dir
            Write-Output "已同步本地构建前置文件：$dir"
            $count++
        }
    }
    Write-Output "共完成 $count 条车道环境同步。"
}

# 安全回收已合入的短命车道工作树并清理对应分支。
function Invoke-LaneCleanup {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw '执行 cleanup 必须通过 `-Name` 指定目标车道名称'
    }
    $lanePath = Join-Path $lanesRoot $Name
    if (-not (Test-Path -LiteralPath $lanePath)) {
        throw "未找到目标车道目录：$lanePath"
    }
    $branchName = (& git -C $lanePath branch --show-current).Trim()
    $dirtyCount = @(& git -C $lanePath status --porcelain).Count
    if ($dirtyCount -gt 0 -and -not $Force) {
        throw "车道 [$Name] 存在 $dirtyCount 处未提交改动，已中止回收（确认丢弃请显式加 -Force）"
    }

    $removeArgs = @('worktree', 'remove')
    if ($Force) { $removeArgs += '--force' }
    $removeArgs += $lanePath
    & git -C $mainRepoRoot @removeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "移除工作树失败：$lanePath"
    }

    if (-not [string]::IsNullOrWhiteSpace($branchName) -and $branchName -ne 'main') {
        $delFlag = if ($Force) { '-D' } else { '-d' }
        & git -C $mainRepoRoot branch $delFlag $branchName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "已同时删除分支：$branchName"
        } else {
            Write-Output "分支 $branchName 尚未合入 main，已保留分支仅移除工作树。"
        }
    }
    Write-Output "车道 [$Name] 回收完成。"
}

# 经跨进程独占文件锁串行执行真机门禁，防止多车道并发争抢设备。
function Invoke-LockedVerify {
    Ensure-FlutterToolchainInPath -RepoRoot $mainRepoRoot
    $psHost = Resolve-PowerShellHost
    $verifyScript = Join-Path $currentWorktreeRoot 'scripts/verify.ps1'
    if (-not (Test-Path -LiteralPath $verifyScript)) {
        throw "当前工作树缺少门禁入口：$verifyScript"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    $lockStream = $null
    $announcedWait = $false
    while ($null -eq $lockStream) {
        try {
            $lockStream = [System.IO.FileStream]::new(
                $hardwareLockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "等待真机硬件互斥锁超时（${LockTimeoutSeconds} 秒）：$hardwareLockPath"
            }
            if (-not $announcedWait) {
                Write-Output "检测到其他车道占用真机设备，排队等待锁释放：$hardwareLockPath"
                $announcedWait = $true
            }
            Start-Sleep -Seconds 2
        }
    }

    try {
        $lockStream.SetLength(0)
        $lockInfo = "pid=$PID`nworktree=$currentWorktreeRoot`nmode=$Mode`nstage=$StageTag`nacquired_at=$(Get-Date -Format 'o')`n"
        $bytes = $utf8NoBom.GetBytes($lockInfo)
        $lockStream.Write($bytes, 0, $bytes.Length)
        $lockStream.Flush()

        & $psHost -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Mode $Mode -StageTag $StageTag
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
    }
}

switch ($Action) {
    'new' { Invoke-LaneNew }
    'status' { Invoke-LaneStatus }
    'sync-env' { Invoke-LaneSyncEnv }
    'cleanup' { Invoke-LaneCleanup }
    'lock-verify' { Invoke-LockedVerify }
}

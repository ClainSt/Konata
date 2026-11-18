param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('init', 'sync-rules', 'status', 'lock-verify')]
    [string]$Action,
    [ValidateSet('Baseline', 'Module', 'Full')]
    [string]$Mode = 'Module',
    [string]$StageTag = 'work',
    [string]$TargetPath = '',
    [int]$LockTimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 解析当前工作树路径与主仓库根目录，避免在不同工作树下调用时写错基准目录。
$currentWorktreeRoot = (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
$worktreeListLines = @(& git -C $currentWorktreeRoot worktree list --porcelain)
if ($LASTEXITCODE -ne 0 -or $worktreeListLines.Count -eq 0) {
    throw '无法读取 `git worktree` 列表，请确认当前处于有效 Git 仓库内'
}
$firstWorktreeLine = @($worktreeListLines | Where-Object { $_.StartsWith('worktree ') }) | Select-Object -First 1
if (-not $firstWorktreeLine) {
    throw '无法从 `git worktree list` 解析主仓库根目录'
}
$mainRepoRoot = (Resolve-Path $firstWorktreeLine.Substring(9).Trim()).Path
$projectsRoot = Split-Path $mainRepoRoot -Parent
$lanesRoot = Join-Path $projectsRoot 'Konata-lanes'
$hardwareLockPath = Join-Path $projectsRoot '.konata-hardware-gate.lock'

# 常驻辅助车道配置表：维护车道用于发布稳态修补，研发车道用于新特性迭代。
$laneSpecs = @(
    @{ Name = 'maint'; Branch = 'release/maint' },
    @{ Name = 'next'; Branch = 'feat/next' }
)

# 受保护的门禁与注释校验脚本清单，初始化与规则同步后必须强制保持只读属性。
$lockedGateScripts = @(
    'scripts/verify.ps1',
    'scripts/verify_gate.ps1',
    'scripts/check_comments.ps1'
)

# 优先使用并自愈注入 `pwsh` 目录，确保 `verify.ps1` 与 `verify_gate.ps1` 子进程可直接调用 `pwsh`。
function Resolve-PowerShellHost {
    $pwshCmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($pwshCmd) { return $pwshCmd.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $pwshDir = Split-Path $candidate -Parent
            $env:PATH = "$pwshDir;$env:PATH"
            return $candidate
        }
    }
    $psCmd = Get-Command 'powershell' -ErrorAction SilentlyContinue
    if ($psCmd) { return $psCmd.Source }
    throw '未找到可用的 PowerShell 执行器'
}

# 从当前环境变量或 `android/local.properties` 提取工具链目录并注入当前进程环境。
function Ensure-FlutterToolchainInPath([string]$RepoRoot) {
    if (Get-Command 'flutter' -ErrorAction SilentlyContinue) {
        return
    }
    $localProps = Join-Path $RepoRoot 'android/local.properties'
    if (Test-Path $localProps) {
        $sdkLine = @([System.IO.File]::ReadAllLines($localProps) | Where-Object { $_.StartsWith('flutter.sdk=') }) | Select-Object -First 1
        if ($sdkLine) {
            $sdkDir = $sdkLine.Substring(12).Replace('\\', '\').Trim()
            $flutterBin = Join-Path $sdkDir 'bin'
            if (Test-Path (Join-Path $flutterBin 'flutter.bat')) {
                $env:PATH = "$flutterBin;$env:PATH"
                return
            }
        }
    }
    if (Test-Path 'D:\FlutterSDK\bin\flutter.bat') {
        $env:PATH = "D:\FlutterSDK\bin;$env:PATH"
        return
    }
    throw '未在系统环境变量或 `local.properties` 中找到 `flutter` 工具链'
}

# 递归复制目录内容，支持按相对路径前缀过滤不应跨越车道的测速证据文件。
function Copy-DirectoryFiltered([string]$SourceDir, [string]$DestDir, [string[]]$ExcludeRelativePrefixes = @()) {
    if (-not (Test-Path $SourceDir)) { return }
    [System.IO.Directory]::CreateDirectory($DestDir) | Out-Null
    $normalizedSource = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
    $items = Get-ChildItem -LiteralPath $SourceDir -Recurse -Force
    foreach ($item in $items) {
        $rel = $item.FullName.Substring($normalizedSource.Length).TrimStart('\', '/').Replace('\', '/')
        $excluded = $false
        foreach ($prefix in $ExcludeRelativePrefixes) {
            $cleanPrefix = $prefix.Trim('/').Replace('\', '/')
            if ($rel -eq $cleanPrefix -or $rel.StartsWith("$cleanPrefix/")) {
                $excluded = $true
                break
            }
        }
        if ($excluded) { continue }
        $targetPath = Join-Path $DestDir $rel
        if ($item.PSIsContainer) {
            [System.IO.Directory]::CreateDirectory($targetPath) | Out-Null
        } else {
            $parentDir = Split-Path $targetPath -Parent
            if ($parentDir) {
                [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $targetPath -Force
        }
    }
}

# 将指定工作树内的三大门禁脚本显式设为只读，防止辅助车道改动或覆盖基线校验规则。
function Lock-GateScriptsReadOnly([string]$WorktreeRoot) {
    foreach ($relPath in $lockedGateScripts) {
        $fullPath = Join-Path $WorktreeRoot $relPath
        if (Test-Path $fullPath) {
            $fileInfo = Get-Item -LiteralPath $fullPath -Force
            if (-not $fileInfo.IsReadOnly) {
                $fileInfo.IsReadOnly = $true
            }
        }
    }
}

# 将主仓库的规则、代理配置与公共资产索引同步覆盖至目标车道（显式排除测速产物）。
function Sync-RulesToWorktree([string]$TargetWorktreeRoot) {
    $syncDirectories = @('.agent', '.codex')
    foreach ($dirName in $syncDirectories) {
        $srcDir = Join-Path $mainRepoRoot $dirName
        $dstDir = Join-Path $TargetWorktreeRoot $dirName
        if (Test-Path $srcDir) {
            Copy-DirectoryFiltered -SourceDir $srcDir -DestDir $dstDir
        }
    }

    $sharedAssetsSrc = Join-Path $mainRepoRoot '.agent-work/SHARED_ASSETS.md'
    if (Test-Path $sharedAssetsSrc) {
        $dstWorkDir = Join-Path $TargetWorktreeRoot '.agent-work'
        [System.IO.Directory]::CreateDirectory($dstWorkDir) | Out-Null
        Copy-Item -LiteralPath $sharedAssetsSrc -Destination (Join-Path $dstWorkDir 'SHARED_ASSETS.md') -Force
    }

    Lock-GateScriptsReadOnly -WorktreeRoot $TargetWorktreeRoot
}

# 新建工作树后补齐未受版本控制的本机工具配置与预编译原生动态库，确保可直接编译运行。
function Copy-UntrackedBuildPrerequisites([string]$TargetWorktreeRoot) {
    $localPropsSrc = Join-Path $mainRepoRoot 'android/local.properties'
    $localPropsDst = Join-Path $TargetWorktreeRoot 'android/local.properties'
    if ((Test-Path $localPropsSrc) -and -not (Test-Path $localPropsDst)) {
        Copy-Item -LiteralPath $localPropsSrc -Destination $localPropsDst -Force
    }

    foreach ($platformSubdir in @('native/konata-native/windows', 'native/konata-native/android')) {
        $srcNative = Join-Path $mainRepoRoot $platformSubdir
        $dstNative = Join-Path $TargetWorktreeRoot $platformSubdir
        if ((Test-Path $srcNative) -and -not (Test-Path $dstNative)) {
            Copy-DirectoryFiltered -SourceDir $srcNative -DestDir $dstNative
        }
    }
}

# 在指定工作树目录内运行包依赖解析，校验原生插件路径注册状态。
function Invoke-PubGetInWorktree([string]$WorktreeRoot) {
    Ensure-FlutterToolchainInPath -RepoRoot $mainRepoRoot
    Push-Location $WorktreeRoot
    try {
        & flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "工作树依赖解析失败：$WorktreeRoot，退出码 $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

# 初始化常驻 `maint` 与 `next` 双工作树并完成规则同步、门禁锁死与依赖准备。
function Invoke-LaneInit {
    [System.IO.Directory]::CreateDirectory($lanesRoot) | Out-Null
    foreach ($spec in $laneSpecs) {
        $laneName = $spec.Name
        $branchName = $spec.Branch
        $lanePath = Join-Path $lanesRoot $laneName
        $created = $false

        if (Test-Path $lanePath) {
            $gitFile = Join-Path $lanePath '.git'
            if (-not (Test-Path $gitFile)) {
                throw "目标路径已存在但并非有效工作树：$lanePath"
            }
            Write-Output "[$laneName] 检测到已存在工作树，跳过创建：$lanePath"
        } else {
            & git -C $mainRepoRoot show-ref --verify --quiet "refs/heads/$branchName"
            $branchExists = ($LASTEXITCODE -eq 0)
            if ($branchExists) {
                & git -C $mainRepoRoot worktree add $lanePath $branchName
            } else {
                & git -C $mainRepoRoot worktree add -b $branchName $lanePath HEAD
            }
            if ($LASTEXITCODE -ne 0) {
                throw "创建 `$laneName` 工作树失败：$lanePath"
            }
            $created = $true
        }

        Sync-RulesToWorktree -TargetWorktreeRoot $lanePath
        Copy-UntrackedBuildPrerequisites -TargetWorktreeRoot $lanePath
        if ($created -or -not (Test-Path (Join-Path $lanePath '.dart_tool/package_config.json'))) {
            Invoke-PubGetInWorktree -WorktreeRoot $lanePath
        }
    }
    Lock-GateScriptsReadOnly -WorktreeRoot $mainRepoRoot
    Write-Output '常驻车道初始化与同步完成。'
}

# 将主仓库最新的开发规则、代理模板与公共资产索引全量覆盖至全部已存在车道。
function Invoke-LaneSyncRules {
    Lock-GateScriptsReadOnly -WorktreeRoot $mainRepoRoot
    if (-not (Test-Path $lanesRoot)) {
        Write-Output "尚未找到车道目录：$lanesRoot"
        return
    }
    $syncedCount = 0
    foreach ($spec in $laneSpecs) {
        $lanePath = Join-Path $lanesRoot $spec.Name
        if (Test-Path (Join-Path $lanePath '.git')) {
            Sync-RulesToWorktree -TargetWorktreeRoot $lanePath
            Write-Output "[$($spec.Name)] 规则与只读门禁脚本同步完成：$lanePath"
            $syncedCount++
        }
    }
    Write-Output "共同步 $syncedCount 条常驻工作树车道。"
}

# 采集并打印单个仓库或工作树的分支、脏文件数及最近提交摘要。
function Format-WorktreeStatusRow([string]$SlotName, [string]$RepoPath) {
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
        return "$SlotName | 未初始化 | - | - | $RepoPath"
    }
    $branch = (& git -C $RepoPath branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = '(HEAD 游离)'
    }
    $dirtyLines = @(& git -C $RepoPath status --porcelain)
    $dirtyCount = $dirtyLines.Count
    $lastCommit = (& git -C $RepoPath log -1 --pretty=format:"%h %s")
    return "$SlotName | $branch | 未提交: $dirtyCount | $lastCommit | $RepoPath"
}

# 汇总展示主仓库与常驻双车道的实时 Git 状态。
function Invoke-LaneStatus {
    Write-Output '=== Konata 三车道工作树状态快照 ==='
    Write-Output (Format-WorktreeStatusRow -SlotName 'main' -RepoPath $mainRepoRoot)
    foreach ($spec in $laneSpecs) {
        $lanePath = Join-Path $lanesRoot $spec.Name
        Write-Output (Format-WorktreeStatusRow -SlotName $spec.Name -RepoPath $lanePath)
    }
}

# 使用跨进程独占文件锁串行化执行真机验收门禁，防止并发争抢手机、平板及调试端口。
function Invoke-LockedVerify {
    Ensure-FlutterToolchainInPath -RepoRoot $mainRepoRoot
    $psHost = Resolve-PowerShellHost
    $verifyScript = Join-Path $currentWorktreeRoot 'scripts/verify.ps1'
    if (-not (Test-Path $verifyScript)) {
        throw "当前工作树缺少验证脚本：$verifyScript"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    $lockStream = $null
    $announcedWait = $false

    # 通过操作系统的独占文件共享模式轮询获取全局真机互斥锁。
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
                Write-Output "检测到其他车道正在占用真机设备，等待锁释放：$hardwareLockPath"
                $announcedWait = $true
            }
            Start-Sleep -Seconds 2
        }
    }

    try {
        # 写入当前持锁进程元信息以便人工排障查看当前占锁车道。
        $lockStream.SetLength(0)
        $lockInfo = "pid=$PID`nworktree=$currentWorktreeRoot`nmode=$Mode`nstage=$StageTag`nacquired_at=$(Get-Date -Format 'o')`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockInfo)
        $lockStream.Write($bytes, 0, $bytes.Length)
        $lockStream.Flush()

        $verifyArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifyScript, '-Mode', $Mode, '-StageTag', $StageTag)
        if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
            $verifyArgs += @('-TargetPath', $TargetPath)
        }

        & $psHost @verifyArgs
        $verifyExitCode = $LASTEXITCODE
        if ($verifyExitCode -ne 0) {
            exit $verifyExitCode
        }
    } finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }
}

switch ($Action) {
    'init' { Invoke-LaneInit }
    'sync-rules' { Invoke-LaneSyncRules }
    'status' { Invoke-LaneStatus }
    'lock-verify' { Invoke-LockedVerify }
}

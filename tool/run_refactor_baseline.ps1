param(
    [ValidateSet('existing-tests', 'characterization', 'analyze', 'format', 'benchmark', 'windows', 'android')]
    [string] $Stage = 'characterization',
    [string] $OutputDirectory = 'build/refactor-baseline',
    [string] $JavaHome = $env:JAVA_HOME
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $project
$oldJava = $env:JAVA_HOME
$oldValidation = $env:KONATA_RELEASE_VALIDATION
try {
    $local = Get-Content -Raw android/local.properties | ConvertFrom-StringData
    $flutter = Join-Path $local['flutter.sdk'] 'bin/flutter.bat'
    $dart = Join-Path $local['flutter.sdk'] 'bin/cache/dart-sdk/bin/dart.exe'
    $null = New-Item -ItemType Directory -Force -Path $OutputDirectory
    $executable = $flutter
    $arguments = switch ($Stage) {
        'existing-tests' { @('test', '--no-pub', '--reporter', 'json') }
        'characterization' { @('test', '--no-pub', '--concurrency=1', 'test/refactor_baseline_contract_test.dart', 'test/refactor_baseline_lifecycle_test.dart', '--reporter', 'json') }
        'analyze' { @('analyze', '--no-pub') }
        'format' {
            $executable = $dart
            @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test', 'integration_test', 'tool')
        }
        'benchmark' { @('test', '--no-pub', '--concurrency=1', 'tool/refactor_baseline_benchmark_test.dart', '--reporter', 'json') }
        'windows' { @('build', 'windows', '--release', '--no-pub') }
        'android' {
            if (!$JavaHome) { throw 'Supply -JavaHome for the existing JDK; this script installs nothing.' }
            $env:JAVA_HOME = $JavaHome
            $env:KONATA_RELEASE_VALIDATION = '1'
            @('build', 'apk', '--release', '--no-pub', '--target-platform', 'android-arm64', '--split-per-abi')
        }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & $executable @arguments *> (Join-Path $OutputDirectory "$Stage.log")
    $result = $LASTEXITCODE
    @{
        command = @($executable) + $arguments
        exitCode = $result
        seconds = $clock.Elapsed.TotalSeconds
        finishedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory "$Stage-result.json")
    Write-Output "$Stage exit=$result; logs: $OutputDirectory"
} finally {
    $env:JAVA_HOME = $oldJava
    $env:KONATA_RELEASE_VALIDATION = $oldValidation
    Pop-Location
}
exit $result

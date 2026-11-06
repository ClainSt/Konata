param([Parameter(Mandatory=$true)][string]$Adb,[Parameter(Mandatory=$true)][string]$Serial,[int]$Port=18763)
$ErrorActionPreference='Stop'
# Only reverses a loopback test-fixture server. Never writes app/media folders.
& $Adb -s $Serial reverse "tcp:$Port" "tcp:$Port"
if($LASTEXITCODE-ne0){throw 'Failed to configure local fixture transport'}
Write-Output "Use PLAYBACK_FIXTURE_URL=http://127.0.0.1:$Port in the isolated validation package."

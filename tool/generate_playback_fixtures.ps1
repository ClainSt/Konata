param(
  [Parameter(Mandatory=$true)][string]$Ffmpeg,
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '../.dart_tool/playback-fixtures')
)
$ErrorActionPreference='Stop'
$fixtureRoot=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
# Synthetic sources only. Never reads, overwrites or re-encodes user videos.
$specs=@(
  @{name='h264-8-1080.mkv';size='1920x1080';codec='libx264';pixel='yuv420p';hdr=$false},
  @{name='h264-hi10-1080.mkv';size='1920x1080';codec='libx264';pixel='yuv420p10le';hdr=$false},
  @{name='hevc-main10-1080.mkv';size='1920x1080';codec='libx265';pixel='yuv420p10le';hdr=$false},
  @{name='hevc-main10-4k.mkv';size='3840x2160';codec='libx265';pixel='yuv420p10le';hdr=$false},
  @{name='hevc-main10-4k-hdr.mkv';size='3840x2160';codec='libx265';pixel='yuv420p10le';hdr=$true}
)
foreach($spec in $specs) {
  $destination=Join-Path $fixtureRoot $spec.name
  if(Test-Path -LiteralPath $destination) {throw "Fixture already exists; choose a new output directory: $destination"}
  $arguments=@('-hide_banner','-loglevel','error','-n','-f','lavfi','-i',"testsrc2=size=$($spec.size):rate=24:duration=4",'-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=4','-c:v',$spec.codec,'-preset','ultrafast','-crf','20','-pix_fmt',$spec.pixel,'-threads','2','-c:a','flac','-shortest')
  if($spec.codec -eq 'libx265') {
    $parameters='pools=2:frame-threads=2:log-level=error'
    if($spec.hdr) {$parameters+=':colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400'}
    else {$parameters+=':colorprim=bt709:transfer=bt709:colormatrix=bt709'}
    $arguments+=@('-x265-params',$parameters)
  }
  if($spec.hdr) {$arguments+=@('-color_primaries','bt2020','-color_trc','smpte2084','-colorspace','bt2020nc')}
  else {$arguments+=@('-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709')}
  & $Ffmpeg @arguments $destination
  if($LASTEXITCODE -ne 0) {throw "FFmpeg failed: $($spec.name)"}
  Write-Output "Generated $($spec.name)"
}
$subtitle=Join-Path $fixtureRoot 'probe.ass'
if(Test-Path -LiteralPath $subtitle) {throw 'Subtitle fixture already exists'}
$ass=@'
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Microsoft YaHei,56,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,30,30,40,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\fad(100,100)}简体字幕／繁體字幕 ASS Test
Dialogue: 1,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\an7\move(70,95,300,95)\bord3\shad2\c&H55DDFF&\t(0,1800,\fscx125)}日本語 English
'@
[IO.File]::WriteAllText($subtitle,$ass,[Text.UTF8Encoding]::new($false))
Write-Output "Fixtures: $fixtureRoot (HDR sample has synthetic SDR code values with HDR metadata; no HDR visual reference)"

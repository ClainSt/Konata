$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$source = [Drawing.Image]::FromFile((Join-Path $root 'assets/brand/icons/windows.png'))
$androidSource = [Drawing.Image]::FromFile((Join-Path $root 'assets/brand/icons/android.png'))
function Export-IconPng($path, [int]$size, [bool]$white, [bool]$adaptive, $inputImage) {
  $bitmap = New-Object Drawing.Bitmap $size,$size
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear($(if ($white) {[Drawing.Color]::White} else {[Drawing.Color]::Transparent}))
  $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
  # Keep the detached corner stars inside the adaptive icon's circular safe area.
  if ($adaptive) { $edge = $size * 0.48; $offset = ($size - $edge) / 2 } else { $offset = 0; $edge = $size }
  $graphics.DrawImage($inputImage, [single]$offset, [single]$offset, [single]$edge, [single]$edge)
  $bitmap.Save((Join-Path $root $path), [Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose(); $bitmap.Dispose()
}
$densities = @{'mdpi'=48; 'hdpi'=72; 'xhdpi'=96; 'xxhdpi'=144; 'xxxhdpi'=192}
foreach ($density in $densities.Keys) {
  $folder = "android/app/src/main/res/mipmap-$density"
  Export-IconPng "$folder/ic_launcher.png" $densities[$density] $true $false $androidSource
  Export-IconPng "$folder/ic_launcher_foreground.png" ([int]($densities[$density] * 2.25)) $false $true $source
}
$sizes = @(16,24,32,48,64,128,256)
$streams = @()
foreach ($size in $sizes) {
  $bitmap = New-Object Drawing.Bitmap $size,$size
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.DrawImage($source,0,0,$size,$size)
  $stream = New-Object IO.MemoryStream
  $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
  $streams += ,$stream.ToArray()
  $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$file = [IO.File]::Create((Join-Path $root 'windows/runner/resources/app_icon.ico'))
$writer = New-Object IO.BinaryWriter $file
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i=0; $i -lt $sizes.Count; $i++) {
  $dimension = if ($sizes[$i] -eq 256) {0} else {$sizes[$i]}
  $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
  $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
  $writer.Write([uint32]$streams[$i].Length); $writer.Write([uint32]$offset)
  $offset += $streams[$i].Length
}
foreach ($bytes in $streams) { $writer.Write([byte[]]$bytes) }
$writer.Dispose(); $source.Dispose(); $androidSource.Dispose()

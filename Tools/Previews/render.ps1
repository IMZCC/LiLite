$ErrorActionPreference = 'Stop'
$nativeRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$outputPath = Join-Path $nativeRoot 'dist\Previews\2026-11-13'
$browserPath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (-not (Test-Path -LiteralPath $browserPath)) { throw 'Chrome executable is unavailable' }
wsl.exe -d SwiftUI-Noble --cd /mnt/d/biliios/Native --exec python3 Tools/Previews/generate.py
if ($LASTEXITCODE -ne 0) { throw 'Preview generation failed' }
$previewJobs = @(
  @{ Name = 'home'; Width = 430; Height = 932 },
  @{ Name = 'video'; Width = 430; Height = 932 },
  @{ Name = 'search'; Width = 430; Height = 932 },
  @{ Name = 'profile'; Width = 430; Height = 932 },
  @{ Name = 'settings'; Width = 430; Height = 932 },
  @{ Name = 'home-dark'; Width = 430; Height = 932 },
  @{ Name = 'fullscreen'; Width = 932; Height = 430 },
  @{ Name = 'overview-main'; Width = 1446; Height = 1160 },
  @{ Name = 'overview-extra'; Width = 988; Height = 1160 }
)
foreach ($job in $previewJobs) {
  $previewUrl = ([uri](Join-Path $outputPath ($job.Name + '.html'))).AbsoluteUri
  $screenshotPath = Join-Path $outputPath ($job.Name + '.png')
  $profilePath = Join-Path $outputPath 'chrome-profile'
  & $browserPath --headless=new --no-first-run --no-default-browser-check --disable-background-networking --disable-sync --hide-scrollbars "--user-data-dir=$profilePath" "--window-size=$($job.Width),$($job.Height)" --force-device-scale-factor=2 --virtual-time-budget=1500 "--screenshot=$screenshotPath" $previewUrl 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $screenshotPath)) { throw ('Screenshot failed: ' + $job.Name) }
  Write-Output ('Rendered ' + $job.Name + '.png')
}

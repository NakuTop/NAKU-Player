param(
  [string]$Flutter = 'flutter',
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '../dist/windows'),
  [string]$ISCC = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Push-Location $root
try {
  & $Flutter pub get
  if ($LASTEXITCODE) { throw 'Flutter dependency resolution failed' }
  & $Flutter build windows --release --no-pub
  if ($LASTEXITCODE) { throw 'Windows build failed' }
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  $redistVersion = Get-ChildItem (Join-Path $vs 'VC/Redist/MSVC') -Directory |
    Where-Object Name -Match '^\d' | Sort-Object Name -Descending | Select-Object -First 1
  $crt = Join-Path $redistVersion.FullName 'x64/Microsoft.VC143.CRT'
  if (!(Test-Path $crt)) { throw 'MSVC x64 redistribution files not found' }
  Copy-Item (Join-Path $crt '*.dll') 'build/windows/x64/runner/Release' -Force
  New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
  $absoluteOutput = (Resolve-Path $OutputDirectory).Path
  & $ISCC "/DOutputDir=$absoluteOutput" 'windows/installer.iss'
  if ($LASTEXITCODE) { throw 'Installer compilation failed' }
  Get-ChildItem $absoluteOutput -Filter '*.exe' | Get-FileHash -Algorithm SHA256
} finally {
  Pop-Location
}

param(
  [string]$CacheDirectory = (Join-Path $PSScriptRoot '../build/ai-downloads'),
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '../build/windows/x64/runner/Release/ai-runtime')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $CacheDirectory,$OutputDirectory -Force | Out-Null
function Get-VerifiedFile([string[]]$Urls, [string]$Path, [string]$Hash) {
  if ((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash) { return }
  $partial = "$Path.download"
  foreach ($url in $Urls) {
    & curl.exe -f -L --retry 2 --connect-timeout 15 --max-time 600 -o $partial $url
    if ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -eq $Hash) {
      Move-Item -LiteralPath $partial -Destination $Path -Force
      return
    }
  }
  throw "Download or checksum verification failed: $Path"
}
$archive = Join-Path $CacheDirectory 'whisper.zip'
$model = Join-Path $CacheDirectory 'ggml-base.bin'
Get-VerifiedFile @('https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-bin-x64.zip') $archive '6ba69e3482d7826214f90a6a9c84ca07782aec1e1d0c6a7c30c994fd5d816ccb'
Get-VerifiedFile @('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin','https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin') $model '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'
$unpacked = Join-Path $CacheDirectory 'whisper'
Expand-Archive -LiteralPath $archive -DestinationPath $unpacked -Force
Copy-Item -LiteralPath (Join-Path $unpacked 'Release/whisper-server.exe') -Destination $OutputDirectory -Force
Get-ChildItem (Join-Path $unpacked 'Release') -Filter '*.dll' | Where-Object { $_.Name -match '^(whisper|ggml|ggml-base|ggml-cpu-.*)\.dll$' } | Copy-Item -Destination $OutputDirectory -Force
Copy-Item -LiteralPath $model -Destination $OutputDirectory -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../docs/WHISPER_LICENSE.txt') -Destination $OutputDirectory -Force

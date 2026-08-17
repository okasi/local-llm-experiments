$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$RuntimeDir = Join-Path $Root "runtime"
$Build = "b10453"
$ServerZip = "llama-$Build-bin-win-cuda-12.4-x64.zip"
$CudartZip = "cudart-llama-bin-win-cuda-12.4-x64.zip"
$Server = Join-Path $RuntimeDir "llama-server.exe"

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

if (Test-Path -LiteralPath $Server) {
    Write-Host "llama-server already present: $Server"
    & $Server --version 2>&1
    exit 0
}

# CUDA 12.4 build is intentionally used over the 13.x build: it's backward-compatible
# with any driver reporting CUDA 12.x-13.x support, whereas the 13.x build only runs on
# drivers new enough to match its exact CUDA version. Check with `nvidia-smi`.
foreach ($name in @($ServerZip, $CudartZip)) {
    $url = "https://github.com/ggml-org/llama.cpp/releases/download/$Build/$name"
    $out = Join-Path $RuntimeDir $name
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $out
    Expand-Archive -LiteralPath $out -DestinationPath $RuntimeDir -Force
    Remove-Item -LiteralPath $out -Force
}

if (-not (Test-Path -LiteralPath $Server)) {
    throw "Expected llama-server missing after extract: $Server"
}

Write-Host "Installed: $Server"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $Server --version 2>&1 | ForEach-Object { Write-Host $_ }
$ErrorActionPreference = $prevEap

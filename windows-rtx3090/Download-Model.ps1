$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$ModelDir = Join-Path $Root "models\Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED"
$RepoUrl = "https://huggingface.co/vcruz305/Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED-GGUF/resolve/main"

$files = @(
    "Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED-Q4_K_M.gguf",       # ~16.8GB, main weights
    "mtp-Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED-Q4_0.gguf"      # ~1.9GB, MTP draft head (optional, see -EnableMtp)
)

New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

foreach ($file in $files) {
    $dest = Join-Path $ModelDir $file
    if (Test-Path -LiteralPath $dest) {
        Write-Host "Already present: $dest"
        continue
    }
    $url = "$RepoUrl/$file"
    Write-Host "Downloading $url"
    # curl -C - resumes partial downloads; HF Xet-backed transfers occasionally drop
    # mid-stream on large files, so retry liberally rather than failing outright.
    & curl.exe -sS -L -C - --retry 15 --retry-delay 8 --retry-all-errors -o $dest $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed ($LASTEXITCODE): $url" }
}

Write-Host "Models ready in $ModelDir"

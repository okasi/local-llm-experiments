<#
Launches llama-server for Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED (Q4_K_M), tuned for a
single RTX 3090 (24GB VRAM). Default profile is the full native 262144-token context
with q4_0 KV cache and no MTP draft model -- head-to-head benchmarking (see the root
README) found this 4.7x faster than 163840/q8_0/MTP once real long context is in
play, for statistically identical quality. Pass -EnableMtp for the short-context,
code-heavy case where MTP is still a genuine ~1.7x win.

Model facts (read directly from the GGUF header):
  architecture=qwen35  layers=65  embd=5120  kv_heads=4  head_dim=256  native_ctx=262144
  KV cache uses an MLA-style compressed layout, not plain GQA -- naive bytes/token math
  badly overestimates its footprint, so don't trust a formula here. Measured on this
  hardware instead:

    context   cache    MTP  VRAM        notes
    32768     q8_0     on   19.3 GB     matches model author's own recommendation
    163840    q8_0     on   24.2 GB     loads at full speed, but see below
    184320    q8_0     on   24.1 GB     loads and answers, but collapses to ~1.5 tok/s
                                        (q8_0 hits a slow fallback path on Ampere once
                                        VRAM is this tight -- see community notes)
    200000+   q8_0     on   --          MTP draft model fails to load: "invalid vector
                                        subscript" (reproducible build bug, independent
                                        of free memory)
    262144    q4_0     off  22.0 GB     full native context, normal speed (~39 tok/s)
    262144    q4_0     on   24.2 GB     full native context WITH MTP -- draft cache must
                                        also be q4_0 (q8_0 draft cache still hits the
                                        load crash above ~160-200K even with q4_0 main)

  q4_0 KV cache is what actually gets you to the full 262144 window: it's not just
  smaller than q8_0, on this Ampere GPU q8_0 also runs into a slow flash-attention
  fallback path once VRAM is tight, which q4_0 avoids. f16 cache is *never* the right
  call on a single 24GB card -- it needs double the q8_0 footprint, capping out at a
  SMALLER usable context, despite that being a common tip online (aimed at unified-memory
  hardware with far more addressable RAM than a discrete GPU).

  MTP itself is a wash-to-negative once real long context is in play: a rejected draft
  token still costs a full forward pass, and that pass's attention cost scales with
  context length, so on anything MTP predicts poorly (most prose) every rejection gets
  more expensive as the conversation grows. At 32768 depth on generic content, MTP-off
  measured 17x faster than MTP-on. MTP only clearly wins on code/structured output,
  where draft acceptance is 90%+, and mainly at shallow-to-moderate depth.
#>
param(
    [int]$Port = 8085,
    [string]$BindHost = "127.0.0.1",
    [int]$CtxSize = 262144,
    [int]$Threads = 12,
    [int]$NGL = 999,

    [ValidateSet("default", "minimal", "low", "medium", "high", "xhigh", "max")]
    [string]$ReasoningEffort = "medium",

    [ValidateSet("q8_0", "q4_0", "f16")]
    [string]$CacheType = "q4_0",
    [switch]$MaxContext,       # legacy convenience, now redundant with the defaults above; kept so old invocations still work
    [switch]$NoKvOffload,      # keep KV cache in system RAM instead of VRAM (last resort; see notes above -- compute buffers still need GPU headroom even with this on)
    [switch]$EnableMtp,        # turn MTP back on -- worth it for short/code-heavy sessions, a net loss for long generic-content ones (see header)
    [switch]$DisableMtp,       # deprecated alias, MTP is now off by default -- kept so old invocations still work
    [string[]]$ExtraServerArgs = @()
)

if ($MaxContext) {
    if (-not $PSBoundParameters.ContainsKey("CtxSize")) { $CtxSize = 262144 }
    if (-not $PSBoundParameters.ContainsKey("CacheType")) { $CacheType = "q4_0" }
}
$UseMtp = $EnableMtp -and -not $DisableMtp

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ServerExe = Join-Path $Root "runtime\llama-server.exe"
$ModelDir = Join-Path $Root "models\Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED"
$MainModel = Join-Path $ModelDir "Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED-Q4_K_M.gguf"
$DraftModel = Join-Path $ModelDir "mtp-Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED-Q4_0.gguf"
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

foreach ($required in @($ServerExe, $MainModel)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required file not found: $required (run Install-LlamaCuda.ps1 / Download-Model.ps1 first)" }
}
if ($UseMtp -and -not (Test-Path -LiteralPath $DraftModel)) {
    throw "MTP draft model not found: $DraftModel"
}

# ---- sanity check against measured behavior (see header notes; this model's KV cache
# doesn't follow simple bytes/token math, so we warn off known-bad combos instead) ----
if ($CacheType -eq "f16" -and $CtxSize -gt 16384) {
    Write-Warning "f16 cache above ~16K context will likely fail to allocate on a 24GB card -- it needs 2x q4_0's footprint. Use -CacheType q4_0 instead (verified stable up to the full 262144 context, with MTP)."
}
if ($CacheType -eq "q8_0" -and $CtxSize -gt 163840) {
    Write-Warning "q8_0 cache above ~160K context is known to collapse to ~1.5 tok/s on this GPU (Ampere flash-attention fallback path under VRAM pressure) even though it technically loads. Use -CacheType q4_0 instead, or -MaxContext."
}
if ($UseMtp -and $CtxSize -gt 200000 -and $CacheType -ne "q4_0") {
    Write-Warning "MTP draft model load crashes (\"invalid vector subscript\") above ~160-200K context unless BOTH main and draft cache are q4_0. Use -CacheType q4_0."
}
if ($UseMtp -and $CtxSize -gt 65536) {
    Write-Warning "MTP measured 17x SLOWER than no-MTP at 32768 depth on generic content (rejected drafts get more expensive as context grows). Worth it mainly for short/code-heavy sessions -- see script header. Drop -EnableMtp for long-context use."
}
Write-Host "Cache type: $CacheType | context: $CtxSize | MTP: $(if ($UseMtp) { 'on' } else { 'off' })"

$args = @(
    "--model", $MainModel,
    "--alias", "qwen38-27b-aeon",
    "--host", $BindHost,
    "--port", "$Port",
    "-c", "$CtxSize",
    "-ngl", "$NGL",
    "-fa", "on",
    "--jinja",
    "-np", "1",
    "-t", "$Threads",
    "--reasoning-format", "deepseek",
    "--reasoning-effort", $ReasoningEffort,
    "--cache-type-k", $CacheType,
    "--cache-type-v", $CacheType,
    "--temp", "1.0",
    "--top-p", "0.95",
    "--top-k", "30",
    "--min-p", "0.0",
    "--presence-penalty", "0.0"
)

if ($UseMtp) {
    # draft cache type must match main cache type at large contexts -- a q8_0 draft
    # cache still hits the load-time crash above ~160-200K even when main cache is q4_0
    $draftCacheType = if ($CtxSize -gt 160000) { $CacheType } else { "q8_0" }
    $args += @(
        "--model-draft", $DraftModel,
        "--spec-type", "draft-mtp",
        "--spec-draft-n-max", "2",
        "--spec-draft-type-k", $draftCacheType,
        "--spec-draft-type-v", $draftCacheType
    )
}

if ($NoKvOffload) { $args += "-nkvo" }
if ($ExtraServerArgs.Count -gt 0) { $args += $ExtraServerArgs }

$Out = Join-Path $LogDir "llama-server.out.log"
$Err = Join-Path $LogDir "llama-server.err.log"
Set-Content -LiteralPath $Out -Value "" -Encoding utf8
Set-Content -LiteralPath $Err -Value "" -Encoding utf8

Write-Host ""
Write-Host "Starting llama-server..."
Write-Host "  Main model:  $MainModel"
if ($UseMtp) { Write-Host "  Draft model: $DraftModel" }
Write-Host "  Context:     $CtxSize ($CacheType KV cache)$(if ($NoKvOffload) { ' [CPU RAM]' })"
Write-Host "  Reasoning effort: $ReasoningEffort"
Write-Host ""

$proc = Start-Process -FilePath $ServerExe -ArgumentList $args -WorkingDirectory $Root -RedirectStandardOutput $Out -RedirectStandardError $Err -WindowStyle Hidden -PassThru

$tailJob = Start-Job -ScriptBlock {
    param($ErrPath)
    while (-not (Test-Path -LiteralPath $ErrPath)) { Start-Sleep -Milliseconds 200 }
    Get-Content -LiteralPath $ErrPath -Wait
} -ArgumentList $Err

try {
    $healthy = $false
    for ($i = 0; $i -lt 300; $i++) {
        Start-Sleep -Seconds 2
        Receive-Job -Job $tailJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        if ($proc.HasExited) {
            Write-Host "Server exited during startup (code $($proc.ExitCode)). Last log lines:"
            Get-Content -LiteralPath $Err -Tail 80
            throw "llama-server failed to start"
        }
        try {
            $resp = Invoke-RestMethod -Uri "http://${BindHost}:${Port}/health" -TimeoutSec 2
            if ($resp.status -eq "ok") { $healthy = $true; break }
        } catch { }
        if ($i % 10 -eq 0) { Write-Host "Still loading model... ($($i*2)s)" }
    }

    if (-not $healthy) {
        Write-Host "Server did not become healthy. Last log lines:"
        Get-Content -LiteralPath $Err -Tail 80
        throw "llama-server failed health check"
    }

    Write-Host ""
    Write-Host "Ready: http://${BindHost}:${Port}/v1  (PID $($proc.Id))"
    Write-Host "Logs: $Out / $Err"
    Write-Host "Close this window or Ctrl+C to stop the server."
    Write-Host ""

    while (-not $proc.HasExited) {
        Receive-Job -Job $tailJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Stop-Job -Job $tailJob -ErrorAction SilentlyContinue
    Remove-Job -Job $tailJob -Force -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}

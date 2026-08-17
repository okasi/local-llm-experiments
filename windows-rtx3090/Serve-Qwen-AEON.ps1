<#
Launches llama-server for Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED (Q4_K_M), tuned for a
single RTX 3090 (24GB VRAM). Default profile is the full native 262144-token context
with q4_0 KV cache and no MTP draft model -- head-to-head benchmarking (see bench\report
in this repo) found this 4.7x faster than 163840/q8_0/MTP once real long context is in
play, for statistically identical quality. Pass -EnableMtp for the short-context,
code-heavy case where MTP is still a genuine ~1.7x win (see report SS4).

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

    [switch]$RequireApiKey,    # require --Authorization: Bearer <key>; auto-generates and persists a key to secrets\api-key.txt on first use
    [switch]$Tls,              # serve HTTPS using the self-signed cert in tls\ (run New-SelfSignedCert.ps1 first if it's missing)
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
    if (-not (Test-Path -LiteralPath $required)) { throw "Required file not found: $required" }
}
if ($UseMtp -and -not (Test-Path -LiteralPath $DraftModel)) {
    throw "MTP draft model not found: $DraftModel"
}

# ---- API key (opt-in) -- auto-generates and persists to secrets\api-key.txt on first use.
# That file is deliberately outside anything meant to be committed to git.
$ApiKey = $null
if ($RequireApiKey) {
    $SecretsDir = Join-Path $Root "secrets"
    $ApiKeyFile = Join-Path $SecretsDir "api-key.txt"
    New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
    if (-not (Test-Path -LiteralPath $ApiKeyFile)) {
        $ApiKey = -join ((1..32) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) })
        Set-Content -LiteralPath $ApiKeyFile -Value $ApiKey -NoNewline -Encoding ascii
        Write-Host "Generated new API key, saved to $ApiKeyFile"
    } else {
        $ApiKey = (Get-Content -LiteralPath $ApiKeyFile -Raw).Trim()
    }
}

# ---- TLS (opt-in) -- self-signed cert in tls\, generated once via New-SelfSignedCert.ps1.
# A self-signed cert means clients see a trust warning (or need -k/--insecure with curl) --
# that's expected. It still encrypts the connection, which matters once the API key is
# travelling over the open internet instead of localhost/LAN.
$Scheme = "http"
if ($Tls) {
    $TlsDir = Join-Path $Root "tls"
    $TlsKey = Join-Path $TlsDir "server.key"
    $TlsCert = Join-Path $TlsDir "server.crt"
    if (-not (Test-Path -LiteralPath $TlsKey) -or -not (Test-Path -LiteralPath $TlsCert)) {
        throw "TLS cert/key not found in $TlsDir. Run New-SelfSignedCert.ps1 first."
    }
    $Scheme = "https"
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

# ---- clear out any stale server from a previous run ----
# Start-Process launches llama-server.exe as an independent process, not a true child
# of this console. Closing the console window (the [X] button) sends CTRL_CLOSE_EVENT,
# which Windows can force-tear-down the console session for *before* this script's
# `finally` block gets a chance to run -- so the old server survives, still holding the
# log files open (hence the Set-Content lock error) and the port bound.
$stale = Get-Process llama-server -ErrorAction SilentlyContinue
if ($stale) {
    Write-Warning "Found $($stale.Count) leftover llama-server process(es) from a previous run (likely the console window was closed instead of Ctrl+C). Stopping them."
    $stale | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

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
    "--presence-penalty", "0.0",
    "--no-cors-credentials"    # harmless tightening: we auth via a bearer header, not cookies, so no reason to allow credentialed cross-origin requests
)

if ($ApiKey) { $args += @("--api-key", $ApiKey) }
if ($Tls) { $args += @("--ssl-key-file", $TlsKey, "--ssl-cert-file", $TlsCert) }

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

# ---- console control handler: reliably kills llama-server if this window is closed ----
# A `finally` block only runs on a normal exit or Ctrl+C (which raises a real .NET
# exception PowerShell can catch). Clicking the console window's [X] sends
# CTRL_CLOSE_EVENT, which Windows can act on before `finally` gets scheduled. This
# handler is a native callback the OS invokes directly, so it fires reliably even then.
if (-not ("QwenServerCleanup" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class QwenServerCleanup
{
    private delegate bool HandlerRoutine(uint ctrlType);
    private static readonly HandlerRoutine Handler = new HandlerRoutine(Handle);
    private static int TargetPid = -1;

    [DllImport("kernel32.dll")]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    public static void Install()
    {
        SetConsoleCtrlHandler(Handler, true);
    }

    public static void SetTarget(int pid)
    {
        TargetPid = pid;
    }

    private static bool Handle(uint ctrlType)
    {
        // 0=CTRL_C, 1=CTRL_BREAK, 2=CTRL_CLOSE, 5=CTRL_LOGOFF, 6=CTRL_SHUTDOWN
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
        {
            if (TargetPid > 0)
            {
                try
                {
                    using (Process p = Process.GetProcessById(TargetPid))
                    {
                        if (!p.HasExited) { p.Kill(); }
                    }
                }
                catch { }
            }
        }
        return false;
    }
}
"@
}
[QwenServerCleanup]::Install()

$proc = Start-Process -FilePath $ServerExe -ArgumentList $args -WorkingDirectory $Root -RedirectStandardOutput $Out -RedirectStandardError $Err -WindowStyle Hidden -PassThru
[QwenServerCleanup]::SetTarget($proc.Id)

$tailJob = Start-Job -ScriptBlock {
    param($ErrPath)
    while (-not (Test-Path -LiteralPath $ErrPath)) { Start-Sleep -Milliseconds 200 }
    Get-Content -LiteralPath $ErrPath -Wait
} -ArgumentList $Err

# 0.0.0.0 means "listen on every interface" -- it's not itself a connectable address,
# so our own health probe always targets loopback regardless of what the server binds to.
$HealthCheckHost = if ($BindHost -eq "0.0.0.0") { "127.0.0.1" } else { $BindHost }

# Health checks shell out to curl.exe rather than Invoke-RestMethod: Windows PowerShell
# 5.1's .NET Framework TLS stack fails the handshake against llama-server's OpenSSL 3.x
# listener (tried forcing TLS 1.2 explicitly -- still failed, looks like a cipher-suite
# mismatch, not just a protocol-version one), while curl.exe's independent TLS stack
# connects fine. Without this, every health check silently throws and gets swallowed by
# the retry loop, burning the full timeout against a server that's actually healthy.
function Test-ServerHealthy {
    param([string]$Url, [string]$ApiKey, [bool]$Insecure)
    $curlArgs = @("-s", "-m", "2", "-o", "NUL", "-w", "%{http_code}", $Url)
    if ($Insecure) { $curlArgs = @("-k") + $curlArgs }
    if ($ApiKey) { $curlArgs = @("-H", "Authorization: Bearer $ApiKey") + $curlArgs }
    $code = & curl.exe @curlArgs 2>$null
    return $code -eq "200"
}

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
        if (Test-ServerHealthy -Url "${Scheme}://${HealthCheckHost}:${Port}/health" -ApiKey $ApiKey -Insecure $Tls) {
            $healthy = $true; break
        }
        if ($i % 10 -eq 0) { Write-Host "Still loading model... ($($i*2)s)" }
    }

    if (-not $healthy) {
        Write-Host "Server did not become healthy. Last log lines:"
        Get-Content -LiteralPath $Err -Tail 80
        throw "llama-server failed health check"
    }

    Write-Host ""
    Write-Host "Ready: ${Scheme}://${HealthCheckHost}:${Port}/v1  (PID $($proc.Id))"
    if ($ApiKey) {
        Write-Host "API key required. Example:"
        Write-Host "  curl $(if ($Tls) { '-k ' })${Scheme}://${HealthCheckHost}:${Port}/v1/models -H `"Authorization: Bearer $ApiKey`""
    } else {
        Write-Warning "No API key set -- anyone who can reach this port can use the server. Add -RequireApiKey."
    }
    $lanIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress -Unique
    if ($BindHost -eq "0.0.0.0") {
        foreach ($ip in $lanIps) { Write-Host "LAN:   ${Scheme}://${ip}:${Port}/v1  (reachable from other devices on this network)" }
    } else {
        foreach ($ip in $lanIps) { Write-Host "LAN IP: $ip  (server is bound to $BindHost, NOT reachable from other devices -- pass -BindHost 0.0.0.0 to open it up)" }
    }
    if (-not $lanIps) { Write-Host "LAN:   no private IPv4 address found" }
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

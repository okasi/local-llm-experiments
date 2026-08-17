# Windows RTX 3090 Agent Guide

Run PowerShell commands from `windows-rtx3090/`.

## Architecture

- `Install-LlamaCuda.ps1`: downloads and extracts the llama.cpp CUDA 12.4 prebuilt
  binaries (b10453) into `runtime/`. CUDA 12.4 is used deliberately over the 13.x
  build for driver backward-compatibility -- check `nvidia-smi`'s reported CUDA
  version before assuming a newer build will run.
- `Download-Model.ps1`: downloads the Qwen3.8-27B AEON Q4_K_M weights and MTP draft
  head into `models/`.
- `Serve-Qwen-AEON.ps1`: llama-server lifecycle -- start, wait for `/health`, stream
  logs, clean shutdown on Ctrl+C (and on the console window being closed, see
  Gotchas). `-RequireApiKey` / `-Tls` add auth and encryption; both off by default.
- `New-SelfSignedCert.ps1`: generates the self-signed TLS cert/key pair `-Tls` uses,
  covering `localhost` plus every private IPv4 currently on the machine.
- `Fix-TDR-Timeout.ps1`: one-time admin-only fix for a Windows GPU driver timeout
  that can kill the CUDA context under sustained load (see Gotchas below).
- `bench/Sample-Vram.ps1`: polls `nvidia-smi` on an interval, reports peak/avg VRAM.

## Defaults

- llama.cpp runtime: `runtime/llama-server.exe` (CUDA 12.4 build b10453)
- normal context maximum: `262144` (full native window; this model's KV cache is
  MLA-style, not plain GQA, so naive bytes/token VRAM math badly overestimates its
  footprint -- see measured numbers in the script header)
- KV cache: `q4_0` -- not `q8_0`. On Ampere, `q8_0` hits a slow flash-attention
  fallback path once VRAM is tight, and needs more memory besides; `f16` needs 2x
  `q4_0`'s footprint and is never correct on a single 24GB card despite being a
  common online tip (it's aimed at unified-memory hardware, not a discrete GPU).
- MTP: **off** by default. It's a genuine ~1.7x win on code/structured output at
  shallow-to-moderate depth, but a rejected draft still costs a full forward pass
  whose cost scales with context length -- on generic/unpredictable content at
  depth, measured 17x *slower* than no MTP. Pass `-EnableMtp` for short, code-heavy
  sessions only.
- sampler: `1.0 / 0.95 / 30 / min_p 0.0 / presence_penalty 0.0`
- reasoning effort: `medium` (this model defaults to `xhigh` via its chat template,
  which burns tokens badly overthinking simple prompts -- always pin it explicitly)
- auth/TLS: both **off** by default (matches upstream llama-server). No CORS
  credentials regardless (`--no-cors-credentials` always set; harmless since auth
  is a bearer header, not a cookie). Turn `-RequireApiKey` and `-Tls` on before
  this server is reachable from anywhere you don't already trust -- see Security.

## Commands

```powershell
.\Install-LlamaCuda.ps1
.\Download-Model.ps1
.\Serve-Qwen-AEON.ps1                          # 262144, q4_0, no MTP
.\Serve-Qwen-AEON.ps1 -EnableMtp -CtxSize 32768  # short/code-heavy session
.\Serve-Qwen-AEON.ps1 -RequireApiKey -Tls -BindHost 0.0.0.0  # reachable + auth'd + encrypted
.\bench\Sample-Vram.ps1 -DurationSeconds 120
```

## Security

`-RequireApiKey` generates and persists a random key to `secrets/api-key.txt` on
first use (gitignored, never commit it) and requires it as `Authorization: Bearer
<key>` on inference endpoints -- `/v1/models` stays open by upstream design (no
user data in it). `-Tls` serves HTTPS via a self-signed cert from `New-
SelfSignedCert.ps1` (also gitignored); clients need `-k`/`--insecure` or
equivalent since nothing signed it but itself, but the connection is still
encrypted, which matters once the key is travelling over the open internet
instead of localhost/LAN.

Neither flag does anything about the server being reachable in the first place --
that's `-BindHost 0.0.0.0` plus whatever you do at the router/firewall level
(port forward, tunnel, etc.), which is out of scope for this script on purpose.
`-np 1` means the server is inherently single-request: opening it up, even with
auth, means anyone with the key can fully occupy it with one request.

## Gotchas

- **GPU driver reset under load (WDDM TDR).** Windows resets the GPU driver if a
  single GPU operation runs past a 2-second default timeout. On this hardware the
  trigger was concurrent requests against the single-slot (`-np 1`) server, not
  raw prompt depth as first suspected -- the CUDA context dies silently (VRAM
  usage collapses, the GPU can briefly vanish from Windows' device list) while the
  host process keeps running. Run `Fix-TDR-Timeout.ps1` as Administrator once,
  then reboot. Multi-concurrency testing isn't representative of this server's
  real behavior anyway (`-np 1` only serves one request at a time regardless).
- **MTP draft model load crash above ~160-200K context.** Fails with `invalid
  vector subscript` -- a reproducible bug in this llama.cpp build, independent of
  free memory. Fix is to also set the draft cache type to `q4_0` (matching the
  main cache); a `q8_0` draft cache still crashes even when the main cache is
  `q4_0`. `Serve-Qwen-AEON.ps1` handles this automatically above 160K context.
- **ToolCall-15 scores vary run to run** (97-100 observed on an identical config)
  because sampling runs at `temperature 1.0` unseeded on the model side. Don't
  read a single run's score as a precise measurement; a small gap between two
  configs is noise, not signal.

Models, runtime builds, generated logs, and benchmark run artifacts are
local-only. Record durable results in the root README.

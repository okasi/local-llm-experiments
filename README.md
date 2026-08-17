# Local LLM Experiments

Benchmarks run locally on Windows with llama.cpp Vulkan and on macOS with llama.cpp Metal. New benchmark results should be added to this README when they are run.

Shared LAN/proxy server tooling lives in [`proxy-lan-server/`](proxy-lan-server/). Windows scripts, llama.cpp builds, and benchmark harnesses live in [`windows-strix-halo/`](windows-strix-halo/) (unified-memory APU, Vulkan) and [`windows-rtx3090/`](windows-rtx3090/) (single 24GB discrete GPU, CUDA). macOS M1 Pro Gemma 4 QAT / MTP BenchLoop runs live in [`macos-m1-pro/`](macos-m1-pro/).

The merged Gemma/Qwen harness lives in [`proxy-lan-server/`](proxy-lan-server/): [`proxy.mjs`](proxy-lan-server/proxy.mjs), [`test.mjs`](proxy-lan-server/test.mjs), [`lan-adapter.js`](proxy-lan-server/lan-adapter.js), and [`gemma_qwen_merged_policy.json`](proxy-lan-server/gemma_qwen_merged_policy.json). It is the single shared OpenAI-compatible adapter for BenchLoop, OpenClaw/ClawBench, Hermes Agent, opencode, and similar local agent clients.

## macOS M1 Pro (Metal)

Apple M1 Pro, 32 GB unified memory, llama.cpp Metal. Full macOS notes: [`macos-m1-pro/README.md`](macos-m1-pro/README.md).

**Gemma 4 shared-policy BenchLoop, no cap** (`-c 0`, `--fit-target 28672`, reasoning off). E2B/E4B use no MTP draft; 12B/26B use Unsloth MTP n-max=2. The current merged policy keeps family sampler profiles separate and pinned while sharing generic response behavior. Harness: [`gemma_qwen_merged_policy.json`](proxy-lan-server/gemma_qwen_merged_policy.json).

**Merged Gemma/Qwen v18 q4_0 same-runtime rerun (2026-06-15)** used `q4_0` target and draft KV for matching raw and harness rows. v18 improved quality and overall score on all four Gemma 4 sizes; proxy repair audits found no suspicious prompt/task/answer/action repair labels. Generated run artifacts are intentionally not tracked.

| Model | Runtime | Raw quality | v18 quality | Quality Δ | Raw overall | v18 overall | Overall Δ | v18 dataextract | v18 toolcall |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| E2B | no MTP, `q4_0` KV | 82.4817 | 85.5700 | +3.0883 | 76.3573 | 79.1966 | +2.8393 | 87.23 | 90.00 |
| E4B | no MTP, `q4_0` KV | 81.7217 | 83.3300 | +1.6083 | 74.3993 | 76.2926 | +1.8933 | 91.02 | 75.00 |
| 12B | MTP n-max=2, target/draft `q4_0` KV | 86.2483 | 86.5233 | +0.2750 | 76.6313 | 77.1335 | +0.5021 | 83.38 | 83.33 |
| 26B | MTP n-max=2, target/draft `q4_0` KV | 82.7367 | 83.3250 | +0.5883 | 75.8454 | 76.7168 | +0.8714 | 84.73 | 83.33 |

## Hardware

Runs were done on a Strix Halo mini PC:

- System: `GMKtec NucBox_EVO-X2`
- APU: `AMD Ryzen AI Max+ 395 w/ Radeon 8060S (Strix Halo)`
- CPU: `16` cores / `32` threads
- GPU backend: llama.cpp Vulkan
- System RAM reported by Windows: `32 GiB`
- Vulkan-visible GPU memory in llama.cpp logs: `114507 MiB` total, about `111.82 GiB`, on the Radeon 8060S UMA pool

Unless noted otherwise, we recommend using this profile for the Qwopus 35B no-reasoning WAN/LAN setup:

```powershell
--ctx-size 131072                         # Context window: 128K tokens
-n 32768                                  # Max generated tokens

-ngl 999                                  # Offload all layers to GPU
--flash-attn on                           # Enable Flash Attention
--no-mmap                                 # Better Strix Halo behavior

-b 4096                                   # Prompt batch size
-ub 1024                                  # Micro-batch size
--parallel 1                              # Single active sequence

--cache-type-k q4_0                       # Quantized K cache, saves memory
--cache-type-v q4_0                       # Quantized V cache, saves memory

--temp "0.85"                            # Model-family temperature
--top-k "20"                             # Model-family top-k
--top-p 0.95                              # Nucleus sampling
--min-p 0.0                               # Disable min-p cutoff
--presence-penalty 0.0                    # No topic novelty penalty
--repeat-penalty 1.0                      # No repetition penalty
--seed 3407                               # Reproducible sampling

--reasoning off                           # Disable reasoning mode
--chat-template-kwargs '{"enable_thinking":false,"preserve_thinking":false}' # Disable/purge thinking

--image-min-tokens "1024"        			# Vision token floor

--spec-type draft-mtp                     # Use MTP speculative decoding
--spec-draft-n-min 1                      # Minimum draft tokens
--spec-draft-n-max 2                      # Maximum draft tokens
--spec-draft-type-k q4_0                  # Quantized draft K cache
--spec-draft-type-v q4_0                  # Quantized draft V cache
```

Agent-facing LAN shortcuts for this profile are now aligned to this recommended preset. Native-max benchmark rows and historical tables keep their documented context sizes.

Notes:

- Vision runs used the matching `mmproj` when it loaded successfully.
- `Image gen` is `N/A` when no usable vision run was completed.
- Jackrong Qwopus3.6 35B files are from `Jackrong/Qwopus3.6-35B-A3B-v1-GGUF` (base) and `Jackrong/Qwopus3.6-35B-A3B-v1-MTP-GGUF` (MTP). Vision uses `mmproj.gguf`. **Primary 35B profile:** `Qwopus3.6-35B-A3B-v1-MTP-Q5_K_M.gguf` with Jackrong MTP weights, `--spec-draft-n-max 2`, sampler `0.85 / 0.95 / 20`, `--reasoning off`.
- The 2026-06-09 refresh reran reasoning-on rows with `q8_0/q8_0` KV cache, model-card or family sampler settings, hard TypeScript max output at `7168`, and llama.cpp `b9535` Vulkan. The 2026-06-10 reasoning-off refresh used llama.cpp `b9551` Vulkan.
- The 2026-06-03 requested batch used existing compatible `mmproj` files where they loaded: Gemma E2B with the Unsloth E2B projector and Qwen/Qwopus 27B/35B variants with the matching local 27B/35B projectors.
- `Unsloth Gemma4 E4B` and `Unsloth Gemma4 E2B` required `--image-min-tokens 256` for their `mmproj` files to load; the earlier `1024` setting exceeded their image pixel limits.
- Earlier Gemma4 QAT refresh rows used `--temp 1.0 --top-p 0.95 --top-k 64` and `q8_0/q8_0` KV cache; current serving and benchmark defaults use `q4_0/q4_0` target and draft KV unless a matrix overrides it. Per the [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4), E2B/E4B native context is 128K (`131072`); 12B, 26B A4B, and 31B native context is 256K (`262144`). Local Unsloth QAT GGUFs match those `n_ctx_train` values. The 12B, 26B, and 31B QAT rows used `--cache-ram 0 --ctx-checkpoints 0` for stable vision/cache behavior.
- Qwopus rows use native `262144` context per the [Qwen3.6](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) model card and matching GGUF `n_ctx_train`.
- `Jackrong Qwopus3.6 27B v2 MTP` rows used `--spec-type draft-mtp --spec-draft-n-min 1 --spec-draft-n-max 2`; the 2026-06-06 sampler sweep used `mmproj-F32.gguf` from the MTP repo snapshot.

## Reasoning-Off 131K q4_0 MTP Toggle BenchLoop (2026-06-15)

BenchLoop v0.2.3 raw rerun with family sampler settings, `--ctx-size 131072`, target KV `q4_0/q4_0`, draft KV `q4_0/q4_0` for MTP rows, and reasoning disabled with `--reasoning off --reasoning-budget -1 --chat-template-kwargs '{"enable_thinking":false,"preserve_thinking":false}'`. MTP rows use Gemma draft models, Jackrong MTP GGUFs, or embedded bytkim MTP GGUFs; no-MTP rows omit speculative decoding. BenchLoop has no image suite, so these rows were run without `mmproj`. E4B MTP used `--flash-attn on` because q4_0 V-cache requires flash attention in this llama.cpp build.

The initial full run used `--reasoning-format none`, which left leading thought markers in `message.content` for the larger Gemma and Qwopus rows. The table below keeps the original full-run speed, coding, toolcall, agent, and reasonmath scores, and replaces only the affected `dataextract` and `instructfollow` scores with reduced-suite reruns through the thought-strip proxy. E2B/E4B did not emit those markers and remain from the original full runs.

Config: [`reasoning-off-131k-q4-mtp-toggle.json`](windows-strix-halo/configs/reasoning-off-131k-q4-mtp-toggle.json). Reduced-suite manifest: local ignored `windows-strix-halo/logs/rerun-131k-q4-mtp-toggle-affected-suites.json`.

| Model / file | Mode | Max ctx | Sampler | BL overall | BL quality | BL speed | BL gen | Coding | Toolcall | Agent | Dataextract | Instructfollow | Reasonmath |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` | MTP | 131072 | `1.0 / 0.95 / 64` | 80.0 | 82.5 | 80.3 | 85.62 tok/s | 91.7 | 90.0 | 96.9 | 68.7 | 67.8 | 80.0 |
| `gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` | No MTP | 131072 | `1.0 / 0.95 / 64` | 79.9 | 83.1 | 78.3 | 74.84 tok/s | 100.0 | 90.0 | 96.9 | 70.9 | 67.8 | 73.3 |
| `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` | MTP | 131072 | `1.0 / 0.95 / 64` | 78.7 | 82.8 | 74.3 | 60.28 tok/s | 100.0 | 80.0 | 96.9 | 76.8 | 63.3 | 80.0 |
| `gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf` | No MTP | 131072 | `1.0 / 0.95 / 64` | 77.0 | 82.2 | 69.0 | 44.22 tok/s | 100.0 | 75.0 | 96.9 | 81.0 | 63.3 | 77.0 |
| `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf` | MTP | 131072 | `1.0 / 0.95 / 64` | 81.1 | 86.9 | 65.6 | 36.86 tok/s | 100.0 | 83.3 | 96.9 | 81.2 | 80.0 | 80.0 |
| `gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf` | MTP | 131072 | `1.0 / 0.95 / 64` | 80.1 | 84.1 | 73.9 | 58.81 tok/s | 91.7 | 83.3 | 96.9 | 80.4 | 85.6 | 66.7 |
| `Qwen3.6-27B-MTP-pi-tune-Q4_K_M.gguf` | MTP | 131072 | `0.85 / 0.95 / 20` | 76.3 | 84.3 | 52.6 | 17.58 tok/s | 93.8 | 83.3 | 96.9 | 84.3 | 67.8 | 80.0 |
| `Qwopus3.6-27B-Coder-MTP-Q3_K_M.gguf` | MTP | 131072 | `0.85 / 0.95 / 20` | 76.8 | 85.4 | 53.6 | 18.75 tok/s | 100.0 | 86.7 | 96.9 | 77.5 | 71.1 | 80.0 |
| `Qwopus3.6-35B-A3B-v1-MTP-Q5_K_M.gguf` | MTP | 131072 | `0.85 / 0.95 / 20` | 78.3 | 83.9 | 69.2 | 47.25 tok/s | 93.8 | 96.7 | 96.9 | 78.4 | 64.5 | 73.3 |
| `gemma-4-31B-it-qat-UD-Q4_K_XL.gguf` | MTP | 131072 | `1.0 / 0.95 / 64` | 80.8 | 89.2 | 54.6 | 19.87 tok/s | 100.0 | 83.3 | 96.9 | 89.3 | 85.6 | 80.0 |

## Windows RTX 3090 (CUDA)

Single discrete 24GB GPU, llama.cpp CUDA. Full setup, benchmark tables, and debugging notes: [`windows-rtx3090/`](windows-rtx3090/), [`windows-rtx3090/AGENTS.md`](windows-rtx3090/AGENTS.md). Full interactive report with per-depth tables: [bench report](https://claude.ai/code/artifact/bc4d5133-c909-4dc3-9bd9-6fc7d93af8b0).

### Hardware

- CPU: `AMD Ryzen 9 7940HS` (8 cores / 16 threads) -- a mobile chip, GPU is very likely attached via eGPU (Thunderbolt/USB4/Oculink)
- GPU: `NVIDIA GeForce RTX 3090`, 24576 MiB VRAM, WDDM driver model
- System RAM: `32 GiB`
- Runtime: llama.cpp CUDA 12.4 prebuilt binaries, build `b10453`

### Model

`vcruz305/Qwen3.8-27B-AEON-ULTIMATE-UNCENSORED-GGUF`, Q4_K_M (16.8GB) + MTP draft head Q4_0 (1.9GB). Architecture `qwen35`, 65 layers, native `262144` context. Its KV cache is MLA-style (compressed), not plain GQA -- naive bytes/token math badly overestimates VRAM cost; the measured numbers below are what to trust instead.

### Recommended profile: full native context, no MTP

```powershell
-c 262144 -ngl 999 -fa on --jinja -np 1 -t 12       # full native context window
--cache-type-k q4_0 --cache-type-v q4_0             # not q8_0 -- see notes
--reasoning-format deepseek --reasoning-effort medium  # model defaults to xhigh, badly overthinks simple prompts
--temp 1.0 --top-p 0.95 --top-k 30 --min-p 0.0 --presence-penalty 0.0
```

MTP (`--model-draft ... --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-type-k/v q4_0`) is available via `-EnableMtp` but **off by default** -- see the reversal finding below.

### Context-length ceiling (measured, main model + MTP draft loaded, `-ngl 999`)

| Context | Cache | MTP | VRAM | Result |
|---|---|---|---:|---|
| 32768 | q8_0 | on | 19.3 GB | matches model author's own recommended default |
| 163840 | q8_0 | on | 24.2 GB | stable, full speed |
| 184320 | q8_0 | on | 24.1 GB | loads and answers, but collapses to ~1.5 tok/s (q8_0 hits a slow flash-attention fallback path on Ampere once VRAM is this tight) |
| 200000+ | q8_0 | on | -- | MTP draft model fails to load: `invalid vector subscript` (reproducible build bug, independent of free memory) |
| **262144 (full native)** | **q4_0** | off | 22.0 GB | stable, normal speed (~39 tok/s) |
| **262144 (full native)** | **q4_0** | on | 24.2 GB | stable -- draft cache must *also* be q4_0, a q8_0 draft cache still crashes at load even with a q4_0 main cache |

f16 cache is never correct here: it needs 2x q4_0's footprint on this hardware, so it caps out at a *smaller* usable context than q4_0, not a larger one -- despite that being a common online tip (aimed at unified-memory hardware with far more addressable RAM than a discrete GPU, not a single 24GB card).

### The MTP reversal: content-dependent, and it flips hard at depth

Single-stream decode tok/s, matched depths, generic (non-code) content:

| Depth | 163840/q8_0/MTP | 262144/q4_0/no-MTP |
|---|---:|---:|
| 0 | 13.8 | 29.1 |
| 8192 | 2.0 | 11.2 |
| 32768 | 0.2 | 3.5 |

Real-world confirmation -- ToolCall-15 category I (context/state) scenarios with 50% of each config's context window pre-filled with unrelated content:

| | 163840/q8_0/MTP | 262144/q4_0/no-MTP |
|---|---:|---:|
| Avg time/scenario | 1145s | 244s (**4.7x faster**) |
| Quality score | 85 | 80 (one-scenario gap at unseeded temp 1.0 -- noise, not signal) |

Mechanism: a rejected MTP draft token still costs a full forward pass, and that pass's attention cost scales with total context length -- so on content MTP predicts poorly (most prose), every rejection gets more expensive as the conversation grows, compounding badly. On code/structured output specifically, draft acceptance is 90%+ and MTP is a clean ~1.7x win (55.6 vs 30.8 tok/s at shallow depth) -- the tradeoff is real, just the opposite of "MTP always helps."

### Notes

- Original launch flags (`--top_p`, `--top_k`, `--min_p`, `--presence_penalty`, `--spec-default` alongside `--spec-type`) don't parse or conflict on this llama.cpp build -- use dashed flag names (`--top-p` etc.) and drop `--spec-default`, an unrelated n-gram speculative-decoding preset.
- ToolCall-15 scores on an *identical* config varied 97-100 across runs (unseeded `temperature 1.0` on the model side) -- treat small score gaps between configs as noise, not signal.
- Windows GPU driver TDR (Timeout Detection and Recovery) reset the CUDA context mid-benchmark, triggered by concurrent requests against the single-slot (`-np 1`) server rather than raw context depth. Fixed via `Fix-TDR-Timeout.ps1` (`TdrDelay` 2s -> 10s, admin + reboot required).

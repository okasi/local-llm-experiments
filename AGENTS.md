# Local LLM Agent Guide

## Structure

- `proxy-lan-server/`: shared OpenAI/Anthropic-compatible LAN adapter and Gemma/Qwen response policy.
- `macos-m1-pro/`: Metal serving and BenchLoop entry points for Gemma 4 QAT/MTP.
- `windows-strix-halo/`: Vulkan serving, benchmarking, model resolution, and setup scripts.
- `windows-rtx3090/`: CUDA serving on a single 24GB discrete GPU -- llama.cpp install, model download, and launch scripts.
- `README.md`: durable benchmark results. Generated logs and copied run artifacts are intentionally untracked.

## Data Flow

Clients call `lan-adapter.js`, which normalizes model aliases and protocol shapes before forwarding to either `proxy.mjs` or a raw `llama-server`. The proxy applies the family policy from `gemma_qwen_merged_policy.json` and forwards to the configured upstream. Platform scripts start the upstream, wait for `/health`, then optionally start this adapter chain.

## Development

Use `-b 4096 -ub 1024` for long-context prefill speed in benchmark and LAN shortcut profiles.

```bash
cd proxy-lan-server
npm install
npm test
```

Use the platform `AGENTS.md` before changing launch flags. Keep Gemma defaults at `temp=1.0`, `top_p=0.95`, `top_k=64`, `min_p=0.0`; keep Qwen/Qwopus defaults at `0.85`, `0.95`, `20`, `0.0`. Explicit client sampler values take precedence.

Use `131072` as the normal maximum context unless a larger run is explicitly requested. Keep policy behavior generic: protocol adaptation, parsing, retries, and output normalization only. Do not add benchmark-specific answers or prompt-derived tool calls.

Models, runtime builds, generated logs, and BenchLoop artifacts are local-only. Record promoted benchmark results in the root README.

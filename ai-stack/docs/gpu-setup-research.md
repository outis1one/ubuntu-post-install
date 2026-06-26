# GPU Setup Research: Rack Server AI Workloads

*Last updated: March 22, 2026*

## Goal
Cost-efficient rack-mountable GPU setup for:
1. **LLM coding inference** — Run 32B+ parameter coding models with maximum context windows
2. **Image generation** — ComfyUI / InvokeAI with Stable Diffusion SDXL / Flux

Target servers: Dell R720/R730 or HP DL380 equivalent (2U rack)

## Why 48GB VRAM is the Right Target

### The Problem with 24GB
32B coding models at Q4_K_M quantization use ~20GB of weights, leaving only ~4GB for KV cache
on a 24GB card. This severely limits context window size — the key ingredient for complex
coding sessions where the model needs to understand your entire codebase.

### What 48GB Unlocks
- **32B models at higher quantization** (Q6_K/Q8_0) = better output quality
- **28GB+ free for KV cache** = massive context windows (32K+ tokens)
- **70B models** in aggressive quantization (~12 t/s but functional)
- **Simultaneous model loading** — coding model + image gen model at once
- Room for future larger models without hardware changes

## Best Local Coding Models (2026)

### Qwen 3.5 Family (February 2026 — Gated Delta Networks)

Architecture breakthrough: 3 of every 4 layers use **linear attention** (O(n) scaling),
drastically reducing KV cache memory. These models need far less VRAM for long contexts
than traditional transformers.

| Model | Type | Active Params | Size at Q4_K_M | Max Context | Quality | Notes |
|-------|------|---------------|---------------|-------------|---------|-------|
| **Qwen3.5-35B-A3B** | **MoE** | **3B** | **~12GB** | **262K** | **B+ to A-** | 35B total but only 3B active — quality tracks active params |
| **Qwen3.5-27B** | Dense | 27B | ~17GB | 262K | **A-** | 72.4% SWE-bench, ties GPT-5 mini. The real A- option. |
| **Qwen3.5-122B-A10B** | MoE | 10B | ~76GB | 262K | A | Matches GPT-5 mini across the board |
| **Qwen3.5-9B** | Dense | 9B | ~6GB | 262K | B+ | Fits on any modern GPU |
| **Qwen3.5-4B** | Dense | 4B | ~3GB | 262K | B | Tiny but capable |

**Quality reality check:** MoE models route tokens through only a subset of parameters.
The 35B-A3B activates **3B params per token** — think of it as a smart 7B model, not a 35B.
Quality is closer to B+ for complex coding. The 27B dense model is genuinely A- but needs
17GB weights (leaving less room for context on 32GB). At Q4 quantization there's a further
small quality loss. And 262K is a VRAM ceiling, not a quality guarantee — models degrade
at the edges of their context window. Practical high-quality context is more like 64-128K.

**No local model approaches Claude Opus on hard problems.** The strategy isn't to replace
Opus — it's to offload the 80% of routine work so your Pro plan limits stop being an issue.

### Previous Generation (Still Relevant)

| Model | Size at Q4_K_M | Quality | Notes |
|-------|---------------|---------|-------|
| **Qwen2.5-Coder 32B** | ~20GB | 73.7 Aider (≈ GPT-4o) | FIM king, 92.7% HumanEval |
| **Qwen3-Coder 30B-A3B** (MoE) | ~18GB | #1 SWE-rebench (64.6%) | Only 3.3B active, very fast |
| **Qwen3-Coder-Next 80B** (MoE) | needs 64GB+ RAM offload | Beats Claude Opus 4.6 on SWE-rebench | Hybrid attention, 256K context |

### Honest Assessment: Local vs Claude Code

Nothing local approaches Claude Opus 4.6 quality for complex multi-file agentic coding.
These 32B models are competitive with **GPT-4o** — a tier below Claude Sonnet, two tiers below Opus.

**The real strategy: Drop Max ($100/mo), keep Pro ($20/mo), offload bulk work to local.**

The problem with Pro for large projects: rate limits. A 10,000-line codebase needs the model
to read, understand, and hold context across many files. On Pro you'll hit usage caps mid-session
on complex multi-file work. Max ($100/mo) removes those limits — but that's $80/mo extra.

Local AI eliminates this problem differently:
- **Local model (262K context)**: Reads your entire 10K-line project at once. No rate limits,
  no usage caps, runs 24/7. Handles the bulk work — understanding codebase structure, routine
  bug fixes, simple refactors, code explanation, test writing, boilerplate generation.
- **Claude Pro ($20/mo)**: Reserved for the hard problems — complex multi-file architectural
  changes, subtle bugs that need Opus-level reasoning, code review on critical paths.
  Pro limits are fine when you're only sending Claude the *hard* 20% instead of everything.

This is the unlock: local doesn't replace Claude, it **reduces your Claude usage enough
that Pro limits stop being a problem.** The 80% of routine work that was burning through
your Max quota now runs locally with zero limits.

| Plan | Monthly | What You Get | Limit Problem |
|------|---------|--------------|---------------|
| Max only | $100 | Opus unlimited | Paying $80/mo for unlimited when you don't need it |
| Pro only | $20 | Opus with rate limits | **Hits caps on 10K-line projects** |
| **Pro + Local GPU** | **$29** | Opus for hard stuff + unlimited local | **No caps — bulk work is local** |
| Local only (no Claude) | $9 | A- quality only | Stuck on hard problems with no escape hatch |

## 48GB GPU Market (March 22, 2026 — Real Prices)

| GPU | Arch | Used Price | TDP | Cooling | Tensor Cores | Mem BW |
|-----|------|------------|-----|---------|--------------|--------|
| **Quadro RTX 8000** | Turing (2018) | **$2,000–2,900** | 260W | Passive variant | Yes (576) | 672 GB/s |
| **A40** | Ampere (2020) | **~$5,050+** | 300W | Passive | Yes (336 3rd-gen) | 696 GB/s |
| **RTX A6000** | Ampere (2020) | **~$5,400+** | 300W | Active (blower) | Yes (336 3rd-gen) | 768 GB/s |
| **L40** | Ada (2022) | **~$6,500+** | 300W | Passive | Yes (568 4th-gen) | 864 GB/s |
| **RTX 6000 Ada** | Ada (2022) | **~$6,500+** | 300W | Active | Yes (568 4th-gen) | 960 GB/s |

Sources: eBay active/sold listings, GPUPoet price tracking, Pangoly, CamelCamelCamel (all March 2026)
Note: One outlier RTX 8000 listing at ~$750 exists but is not representative of the market.

### Cheapest 48GB Option: Quadro RTX 8000 Passive ($2,000–2,900)

The RTX 8000 is still the cheapest 48GB card — roughly half the price of an A40 and a
third of an A6000. The passive variant is purpose-built for rack servers — no fan, relies
on chassis airflow, designed for 24/7 operation in 2U/4U systems.

Key advantages over the P40:
- **48GB vs 24GB** — room for models + massive context
- **Has Tensor Cores** (576 Turing) — native FP16, no `--force-fp32` hacks for image gen
- **NVLink support** — pair two for 96GB combined (100 GB/s bidirectional)
- 10W idle power draw

### Cost Reality Check
At $2,000–2,900 the RTX 8000 is a significant investment. The key question: is unified
48GB VRAM worth 4–6x the cost of dual P40s ($400–500)?

**Yes, if** you need large context windows (32K+) for complex coding — KV cache can't
be split across two GPUs without NVLink (which P40s don't have).

**No, if** you're mostly doing short-prompt coding tasks and image gen — dual P40s give
you 48GB total (split) at a fraction of the cost, and each card can handle its own workload.

## RTX 8000 Performance Benchmarks

### LLM Inference (Exllama, 5.0 bpw quantization)

| Model | Context | Prompt Processing | Generation |
|-------|---------|-------------------|------------|
| Qwen3 30B-A3B (MoE) | 8K | 950 t/s | **34 t/s** |
| Qwen3 30B-A3B (MoE) | 16K | 673 t/s | **21 t/s** |
| Qwen3 30B-A3B (MoE) | 32K | 345 t/s | **11 t/s** |
| Llama 3.3 70B | short | 36 t/s | **13 t/s** |
| Llama 3.1 8B | — | — | **72 t/s** |

### Compared to P40 (24GB)

| Metric | P40 (24GB) | RTX 8000 (48GB) |
|--------|-----------|-----------------|
| **Used price** | **$150–320** | **$2,000–2,900** |
| 32B model fit | Barely (~2GB free) | Comfortable (~28GB free) |
| 32B generation speed | ~5-12 t/s (est.) | ~20-34 t/s |
| Max practical context | ~4K tokens | **32K+ tokens** |
| Image gen (SDXL) | ~49s (`--force-fp32`) | Faster (native FP16) |
| Rack server ready | Yes (passive) | Yes (passive variant) |

### Image Generation
The RTX 8000 has Turing Tensor Cores with native FP16 support. Unlike the P40, it does NOT
need `--force-fp32` workarounds. Image gen performance is significantly better than the P40,
though still behind Ampere/Ada cards.

## Budget Build: 2x Quadro RTX 5000 + NVLink ($850 Total)

*The best price-to-capability ratio for local AI coding in 2026.*

### Why This Works Now

Qwen 3.5 (February 2026) introduced **Gated Delta Networks** — 3 out of 4 layers use linear
attention (O(n) scaling) instead of quadratic. KV cache memory usage is dramatically lower
than traditional transformers. A 35B MoE model with 262K context now fits in ~25GB VRAM.

### Hardware

#### GPU: NVIDIA Quadro RTX 5000 (Turing, TU104)

| Spec | Value |
|------|-------|
| VRAM | 16GB GDDR6 |
| CUDA Cores | 3072 |
| Tensor Cores | 384 (Gen 2, FP16) |
| TDP | ~230W |
| NVLink | **Yes — 50 GB/s bidirectional** |
| Form Factor | Dual-slot, blower cooler (rack-friendly) |
| PCIe | 3.0 x16 |
| Used Price | **~$400** |
| Part Number | VCQRTX5000-PB |

#### NVLink Bridge (CRITICAL: RTX 5000 uses a unique smaller connector)

The Quadro RTX 5000 has a **shorter NVLink connector** than all other Quadro RTX cards.
Bridges from the RTX 6000/8000 will NOT physically fit. You must buy the RTX 5000-specific bridge.

| Detail | Value |
|--------|-------|
| Product | NVIDIA Quadro RTX 5000 NVLink HB Bridge 2-Slot |
| SKU | NVLINKX8-2SLOT-PB |
| Part Numbers | 1JF3K, 699-54934-0500-000, 900-54934-0100-000, P4934, 6FY12AA, L55997-001 |
| Price | **~$30-80** (eBay, Amazon) |
| Bandwidth | 50 GB/s total (25 GB/s per direction) |
| Sizing | 2-slot (cards adjacent) or 3-slot (one slot gap — better thermals) |

**Where to buy:**
- eBay: search "Quadro RTX 5000 NVLink" or part numbers P4934 / L55997-001 / 1JF3K
- Amazon: search part number 6FY12AA or 1JF3K

**WARNING:** The 3-slot bridge is recommended over 2-slot. With a 2-slot bridge the cards
sit directly adjacent — the top card's blower intake gets blocked by the bottom card.
A 3-slot bridge leaves an air gap for proper cooling.

#### Motherboard Requirements

| Requirement | Details |
|-------------|---------|
| PCIe slots | Two x16 slots (x8 electrical is fine — LLM inference is VRAM-bound, not PCIe-bound) |
| Slot spacing | Must match your NVLink bridge size (2-slot or 3-slot gap) |
| Power supply | 650W+ minimum (80 PLUS Gold recommended), 850W+ for headroom |
| Power connectors | 2x 8-pin PCIe power (one per card). Do NOT daisy-chain — use separate cables |
| CPU platform | Any modern platform works. Threadripper/Xeon not required |

**Recommended motherboards (workstation/server):**
- Any board with 2x PCIe x16 slots spaced 2-3 slots apart
- Server: Dell R730/R740 with GPU riser (but verify 3-slot bridge clearance in 2U)
- Workstation: MSI X399 Creation, ASUS WS series, Supermicro X11/X12 boards
- Desktop: Most ATX boards with 2 full-length x16 slots work

**Rack server note:** The Quadro RTX 5000's blower cooler exhausts out the bracket —
this works well in rack airflow. If using a 2U server, measure clearance for the NVLink
bridge sitting on top of the cards. A 4U chassis gives the most room.

### What Runs on 16GB (Single RTX 5000 — Start Here)

| Model | Quant | Context | Quality | Notes |
|-------|-------|---------|---------|-------|
| **Qwen3.5-35B-A3B** | Q4_K_L | ~64-128K | **B+** | MoE, 3B active. Good but VRAM is tight — context may be lower |
| Qwen3.5-9B | Q8 | 128K+ | B+ | Fits comfortably, high quant |
| Qwen3.5-4B | Q8 | 262K | B | Tiny model, long context |
| Qwen2.5-Coder-7B | Q8 | 128K | B | Solid for simple tasks |
| Qwen2.5-Coder-14B | Q4_K_M | 16-32K | B+ | Tight fit, limited context |

A single card is a solid start — B+ coding with decent context. But 16GB is the ceiling.
You can't run bigger dense models, can't use higher quantization, and context is squeezed.

### What the Second Card + NVLink Unlocks (32GB)

The second card doesn't just double context — it opens models that **don't fit on 16GB at all:**

| Model | Arch | Quant | Weights | Context | Total VRAM | Quality | **Why it needs 32GB** |
|-------|------|-------|---------|---------|------------|---------|----------------------|
| **Qwen3.5-27B** | **Dense** | **Q4_K_M** | **~17GB** | **128K+** | **~25GB** | **A-** | **17GB weights won't fit on 16GB** |
| **Qwen2.5-Coder-32B** | **Dense** | **Q4_K_M** | **~20GB** | **16-24K** | **~28GB** | **A-** | **20GB weights won't fit on 16GB** |
| Qwen2.5-Coder-14B | Dense | **Q8** | ~16GB | 64K | ~28GB | A- | Q8 quant = better output, needs 16GB for weights alone |
| Qwen3-Coder-Next (80B) | MoE | Q4 | ~20GB | 128K | ~28GB | A | 20GB weights won't fit on 16GB |
| Qwen3.5-35B-A3B | MoE (3B active) | Q4_K_M | ~12GB | 262K | ~25GB | B+ | Fits on 1 card at reduced context, but 32GB = full 262K + headroom |

**The real upgrade isn't 262K context — it's access to dense 27B/32B models that are
genuinely A- quality.** The 35B-A3B MoE runs on both setups, but its 3B active params
limit quality. The Qwen3.5-27B dense model uses all 27B params on every token — that's
the quality jump. And its 17GB of weights physically can't fit on a single 16GB card.

Think of it this way:
- **1 card**: B+ coding (MoE or small dense models, squeezed context)
- **2 cards**: **A- coding** (full dense 27B/32B models, comfortable context, higher quant options)

### Practical Context Windows (Usability, Not Ceilings)

Context window "support" is a ceiling, not what you actually get. VRAM must hold both the
model weights AND the KV cache. What's left after weights determines your real context.
Quality also degrades toward the edges of a model's context window.

**Reference: A 10,000-line codebase ≈ 100-150K tokens** (varies by language/comments).
This Claude Opus session uses a **1 million token** context window for comparison.

#### 1 Card (16GB) — Practical

| Model | Weights | Free for KV | **Usable context** | 10K-line project? |
|-------|---------|-------------|-------------------|-------------------|
| Qwen3.5-35B-A3B (MoE) | ~12GB | ~3GB | **32-50K tokens** | **No — ~1/3 of it** |
| Qwen3.5-9B (dense) | ~6GB | ~9GB | **80-100K tokens** | **Mostly — but B+ quality** |
| Qwen2.5-Coder-14B | ~10GB | ~5GB | **16-24K tokens** | **No — a few files at a time** |

**Workflow on 1 card:** You're feeding files in chunks. Good for "fix this function" or
"explain this file." Not for "read my whole project and refactor the auth system."

#### 2 Cards (32GB via NVLink) — Practical

| Model | Weights | Free for KV | **Usable context** | 10K-line project? |
|-------|---------|-------------|-------------------|-------------------|
| **Qwen3.5-27B (dense)** | ~17GB | ~14GB | **80-128K tokens** | **Yes — most/all of it at A-** |
| Qwen3.5-35B-A3B (MoE) | ~12GB | ~19GB | **128-180K tokens** | **Yes with room to spare (B+)** |
| Qwen2.5-Coder-32B | ~20GB | ~11GB | **32-48K tokens** | **Partial — but strong A- on what it sees** |

**Workflow on 2 cards:** You can dump most/all of a 10K-line project in one shot with the
27B dense model. That's the real workflow change — "here's my whole project, find the bug"
becomes possible locally.

#### vs This Claude Session

| Setup | Usable context | vs Opus 1M | Whole-project workflow? |
|-------|---------------|------------|----------------------|
| 1x RTX 5000 (best) | ~50-100K | 5-10% | No — file by file |
| **2x RTX 5000 (best)** | **~128-180K** | **13-18%** | **Yes — for 10K-line projects** |
| Claude Opus (this session) | 1,000K | 100% | Yes — for anything |

**Neither setup replaces this session** for complex multi-file work across a 50K+ line
codebase. That's why you keep Pro. But 2 cards handles the daily "read my project and
help me code" workflow locally with no rate limits — and that's 80% of the work.

### Squeezing Every Byte: Single-Card Optimization (16GB)

Before buying a second card, stack these techniques. They're cumulative — use all of them
together. The gains compound because they all free VRAM from the same bottleneck: KV cache.

#### 1. Quantize the KV Cache (Biggest Single Win)

By default, llama.cpp stores the KV cache in FP16. That's 2 bytes per value. You can
compress it with zero code changes — just flags:

| Cache Type | Bytes/value | vs FP16 | Quality Impact | Verdict |
|-----------|-------------|---------|----------------|---------|
| FP16 (default) | 2.0 | baseline | none | wasteful on 16GB |
| **Q8_0** | **1.0** | **50% smaller** | **~0.002-0.05 perplexity** | **Always use this** |
| Q4_0 | 0.5 | 75% smaller | ~0.2 perplexity (noticeable) | Use if desperate |
| **Asymmetric: K=Q8_0, V=Q4_0** | **0.75 avg** | **62% smaller** | **Better than uniform Q4** | **Best bang/buck** |

The K cache is more sensitive to quantization than V. Asymmetric (Q8 keys, Q4 values) gives
you ~62% savings with quality closer to Q8 than Q4.

**Concrete example — Qwen3.5-35B-A3B on 1 card (16GB):**
- Weights: ~12GB → 4GB free for KV cache
- FP16 KV cache: 4GB → **~50K context**
- Q8_0 KV cache: 4GB buys 2x → **~100K context**
- K=Q8/V=Q4 KV cache: 4GB buys 2.6x → **~130K context**

That's the difference between "a few files" and "a meaningful chunk of a project."

```bash
# llama.cpp — always use these three flags together
llama-server \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --flash-attn \
  -m model.gguf -ngl 99 -c 131072

# Ollama — set environment variable before starting
export OLLAMA_KV_CACHE_TYPE=q8_0   # or q4_0 for aggressive
export OLLAMA_FLASH_ATTENTION=1
ollama serve
```

#### 2. Flash Attention (Free Speed + VRAM)

Flash attention restructures how attention is computed — instead of materializing the full
attention matrix in VRAM, it computes it in tiles. Result: less VRAM used during inference,
slightly faster, **zero quality loss**.

Always enable it. There's no downside on Turing GPUs with quantized KV cache.

```bash
# llama.cpp
--flash-attn

# Ollama
export OLLAMA_FLASH_ATTENTION=1
```

#### 3. Host-Memory Prompt Caching (`--cram`) — System RAM as L2 Cache

This is the smart use of system RAM. The `--cram` flag in llama-server stores pre-computed
prompt representations in host memory (system RAM). When you send the same system prompt
or reuse a conversation prefix, it skips reprocessing — hot-swaps the cached computation
back onto the GPU.

This doesn't increase context window size, but it **dramatically reduces time-to-first-token**
for repeated workflows (which is most coding — same system prompt, same project context).

```bash
# llama-server with 16GB RAM cache for prompts
llama-server \
  --cram 16384 \
  --cache-type-k q8_0 --cache-type-v q4_0 --flash-attn \
  -m model.gguf -ngl 99 -c 131072
```

Your R720/R730 has 128-384GB of DDR3/DDR4 RAM. Use it. `--cram 65536` (64GB) is reasonable
for a dedicated inference server — it costs nothing, and repeat prompts become near-instant.

#### 4. KV Cache to System RAM (`-nkvo`) — Last Resort for Context

The `-nkvo` (no KV offload) flag moves the entire KV cache to system RAM, freeing all 16GB
of VRAM for model weights. This sounds great but comes with a brutal speed penalty:

| Scenario | Speed Impact |
|----------|-------------|
| Full VRAM (normal) | Baseline (25-35 tok/s) |
| KV in system RAM via PCIe | **5-20x slower** (~2-7 tok/s) |
| KV on NVMe via mmap | **30x+ slower** (~1 tok/s) |

**When it makes sense:** Loading a model that barely doesn't fit (e.g., Qwen3.5-27B dense
at 17GB weights on a 16GB card). You'd get ~2-5 tok/s with KV in RAM — painfully slow, but
it's the difference between "runs slowly" and "doesn't run at all." Fine for a batch job
where you walk away and come back. Not viable for interactive coding.

**Don't do this routinely.** Quantized KV cache (technique #1) is 50-100x better because
the cache stays on the GPU. Only use `-nkvo` for models that literally can't fit otherwise.

#### 5. Pick the Right Architecture (GQA + MoE = VRAM Efficient)

Not all models consume KV cache equally. Modern architectures with **Grouped Query Attention
(GQA)** use far less KV cache than older Multi-Head Attention (MHA):

| Architecture | KV cache at 64K context | Examples |
|-------------|------------------------|---------|
| MHA (old) | ~8-12GB | LLaMA-1, GPT-J |
| **GQA (modern)** | **~1-3GB** | **Qwen3.5 series, LLaMA-3** |
| **GQA + MoE** | **~1.2GB** | **Qwen3.5-35B-A3B** |

The Qwen3.5-35B-A3B is almost purpose-built for your situation: 3B active params (fast on
Turing), MoE architecture (small memory footprint during inference), and GQA (tiny KV cache).
With quantized KV on top of that, 130K+ context on a single 16GB card is realistic.

#### 6. NVMe as mmap Backing Store

Your fast NVMe matters for **model loading**, not inference. llama.cpp uses mmap by default
to stream model weights from disk, so a fast NVMe means:
- Near-instant cold starts (weights stream in as needed)
- Graceful degradation if model slightly exceeds RAM (OS pages out unused layers)

But NVMe is **not** a viable substitute for VRAM during inference. The bandwidth gap is too
large: VRAM runs at ~400 GB/s (RTX 5000), system RAM at ~50-100 GB/s (DDR4 quad-channel),
NVMe at ~3-7 GB/s. Three orders of magnitude difference from VRAM.

**Practical use:** Keep all your GGUF model files on NVMe. Enable mmap (default). That's it.
Don't try to use NVMe as overflow for the KV cache — the latency kills interactive use.

#### Stacking Everything: Revised Single-Card Numbers

| Model | Optimization | Usable Context | Speed | Quality |
|-------|-------------|---------------|-------|---------|
| Qwen3.5-35B-A3B Q4 | None (defaults) | ~32-50K | 25-35 tok/s | B+ |
| Qwen3.5-35B-A3B Q4 | **KV Q8 + flash** | **~80-100K** | **25-35 tok/s** | **B+** |
| Qwen3.5-35B-A3B Q4 | **KV asym + flash** | **~100-130K** | **25-35 tok/s** | **B+ (tiny quality dip)** |
| Qwen3.5-9B Q8 | KV Q8 + flash | ~120-160K | 30-45 tok/s | B |
| Qwen2.5-Coder-14B Q4 | KV Q8 + flash | ~40-64K | 20-30 tok/s | B+ |

Add `--cram` on top for instant repeated prompts. That's your real single-card ceiling.

**The honest answer:** With all optimizations stacked, a single card goes from "a few files
at a time" to "maybe half a 10K-line project." That's a meaningful upgrade from the
unoptimized baseline, but it still doesn't match what 2 cards with a dense 27B model gives
you. The second card isn't about optimization tricks — it's about physics (more VRAM = more
data on the fast bus).

### Estimated Inference Speed

| Model | 1x RTX 5000 | 2x RTX 5000 (NVLink) |
|-------|-------------|---------------------|
| Qwen3.5-35B-A3B Q4 (short ctx) | ~25-35 tok/s | ~25-35 tok/s |
| Qwen3.5-35B-A3B Q4 (128K ctx) | ~10-18 tok/s | ~15-25 tok/s |
| Qwen3.5-35B-A3B Q4 (262K ctx) | Won't fit | ~10-18 tok/s |
| Qwen2.5-Coder-14B Q4 | ~20-30 tok/s | ~25-35 tok/s |

NVLink matters most at large context windows where KV cache spans both cards.
At short contexts that fit on one card, the second GPU adds less benefit.

**Speed reality check:** NVLink doesn't make it faster — it prevents the slowdown you'd get
from PCIe when the model spans both cards. The base speed is still Turing (2018 silicon).
10-35 tok/s is fast enough for coding (you read slower than that), but it's not instant.
The MoE architecture (only 3B active params at inference) is what makes it viable on older
hardware — NVLink just removes the inter-GPU bottleneck for 262K context.

### Image Generation (Included — No Extra Cost)

The RTX 5000 has **384 Tensor Cores with native FP16** — full SDXL/Flux support, no hacks.

| Workload | VRAM Needed | Where It Runs |
|----------|-------------|---------------|
| SDXL (1024x1024) | ~8-10GB | Either card alone |
| Flux Dev | ~12-14GB | Single card (16GB) |
| Flux Dev (high-res / batched) | ~18-24GB | Both cards via NVLink (32GB) |
| ComfyUI / InvokeAI | Works natively | No `--force-fp32` needed |

**Important: 262K context requires both cards unified.** You can't split one off for image
gen and keep 262K. It's one task at a time:

```bash
# CODING SESSION: Both cards unified → 32GB → 262K context
ollama run qwen3.5:35b-a3b-q4_K_M   # Uses both GPUs via NVLink

# IMAGE GEN SESSION: Stop LLM, run image gen on one card (16GB is plenty)
ollama stop                           # Frees VRAM
comfyui --listen 0.0.0.0             # SDXL/Flux fits easily in 16GB

# Swap takes a few seconds, not simultaneous but not painful
```

If you want simultaneous coding + image gen, you'd run a smaller model at shorter context
on one card (e.g., Qwen3.5-35B-A3B at ~64K on 16GB) and image gen on the other. But for
full 262K context, both cards must be dedicated to the LLM.

### Hardware Longevity: 3-5 Years Realistic

- **2026-2027**: Sweet spot. MoE + linear attention models are getting smaller active params.
  32GB unified handles the best coding models at full context. Peak value.
- **2028-2029**: Still useful. The trend is more efficient models, not bigger ones.
  32GB likely still runs the best ~35-70B MoE coding models of that era.
- **2030+**: Questionable. New architectures may need FP8, newer tensor core ops that
  Turing lacks. But VRAM is VRAM — something useful will always run on 32GB.
- **The cards themselves won't die** — Quadro-grade, designed for 24/7 data center use.
  They'll be outclassed before they fail.

### Power Consumption & Cost

| Config | Idle | Load | Monthly (8hr/day @ $0.09/kWh) | Annual |
|--------|------|------|-------------------------------|--------|
| 1x Quadro RTX 5000 | ~15W | ~210W | **~$4.50** | ~$54 |
| 2x Quadro RTX 5000 | ~30W | ~420W | **~$9.00** | ~$108 |

### Software Setup

#### llama.cpp (Recommended — Best Multi-GPU Support)

```bash
# Build with CUDA support
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j$(nproc)

# Download Qwen3.5-35B-A3B GGUF (Q4_K_M)
# Get from: https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF

# Run on dual GPU with NVLink (all optimizations on)
./build/bin/llama-server \
  -m Qwen3.5-35B-A3B-Q4_K_M.gguf \
  -ngl 999 \
  -c 262144 \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --flash-attn \
  --cram 65536 \
  --host 0.0.0.0 \
  --port 8080

# --cache-type-k q8_0 / --cache-type-v q4_0 = asymmetric KV quantization (62% smaller cache)
# --flash-attn = tiled attention (less VRAM, no quality loss)
# --cram 65536 = 64GB host RAM prompt cache (instant repeat prompts)
# llama.cpp auto-detects NVLink and splits layers across both GPUs
# Use -ts 1,1 to manually set equal split if needed

# Single card variant (no NVLink) — same flags, smaller context
./build/bin/llama-server \
  -m Qwen3.5-35B-A3B-Q4_K_M.gguf \
  -ngl 999 \
  -c 131072 \
  --cache-type-k q8_0 \
  --cache-type-v q4_0 \
  --flash-attn \
  --cram 65536 \
  --host 0.0.0.0 \
  --port 8080
```

#### Ollama

```bash
# Requires Ollama v0.17+ for Qwen3.5 support
# NOTE: As of March 2026, some Qwen3.5 GGUFs have compatibility issues
# with Ollama due to mmproj vision files. llama.cpp may be more reliable.

# Environment variables for multi-GPU
export OLLAMA_GPU_SPLIT=16,16        # Equal split across both 16GB cards
export OLLAMA_KV_CACHE_TYPE=q8_0     # Halves KV cache VRAM with minimal quality loss
export OLLAMA_KEEP_ALIVE=24h         # Keep model loaded in VRAM
export OLLAMA_FLASH_ATTENTION=1      # Enable flash attention for VRAM savings

# Pull and run
ollama pull qwen3.5:35b-a3b-q4_K_M
ollama run qwen3.5:35b-a3b-q4_K_M
```

#### Verify NVLink Is Working

```bash
# Check NVLink status
nvidia-smi nvlink --status

# Check NVLink bandwidth
nvidia-smi nvlink -gt d

# Monitor both GPUs during inference
watch -n 0.5 nvidia-smi
```

### Total Cost Summary

| Item | Cost |
|------|------|
| 2x Quadro RTX 5000 | ~$800 |
| NVLink HB Bridge 2-slot (P4934) | ~$50 |
| Dell cables/riser (R720/R730) | ~$60 |
| Dell 1100W PSUs (if needed) | ~$60-100 |
| **Hardware total** | **~$960** |
| Monthly power (2 cards, 8hr/day) | $9/mo |
| Claude Pro subscription (keep) | $20/mo |
| Claude Max subscription (drop) | -$100/mo saved |
| **Net monthly cost** | **$29/mo (was $100/mo)** |

### The Math: Drop Max, Keep Pro, Add Local

| | Year 1 | Year 2 | Year 3 | **3-Year Total** |
|---|--------|--------|--------|-----------------|
| **Claude Max (current)** | $1,200 | $1,200 | $1,200 | **$3,600** |
| **Pro + Local GPU** | $960 + $348 | $348 | $348 | **$2,004** |
| **Savings** | | | | **$1,596** |

You save ~$71/mo after hardware payoff. The GPU pays for itself in **13 months**.
After that, you're saving $80/mo vs Max with no usage limits on bulk work.

### Comparison: This Build vs Alternatives

| Setup | Monthly | 3yr Total | Limits? | Quality |
|-------|---------|-----------|---------|---------|
| **Pro + 2x RTX 5000** | **$29** | **$2,004** | **Unlimited local, Pro limits for Opus** | **A- local, A+ cloud** |
| Pro + 1x RTX 3090 | $25 | $1,620 | Unlimited local (128K ctx), Pro limits | A- local, A+ cloud |
| Pro + RTX 8000 (48GB) | $29 | $3,040+ | Unlimited local, Pro limits | A- local, A+ cloud |
| **Claude Max (no GPU)** | **$100** | **$3,600** | **Unlimited Opus** | **A+ cloud only** |
| Claude Pro only (no GPU) | $20 | $720 | **Hits caps on large projects** | A+ cloud, limited |
| API-only (Opus heavy use) | $500+ | $18,000+ | Pay per token | A+ cloud only |

### Phased Build Plan

**Phase 1 — Start with one card ($400)**
1. Buy Quadro RTX 5000 (VCQRTX5000-PB) — ~$400 on eBay
2. Install in any PCIe x16 slot
3. Install llama.cpp or Ollama v0.17+
4. Run Qwen3.5-35B-A3B at Q4_K_L with 64-128K context
5. Already A- quality for coding — test if local inference fits your workflow

**Phase 2 — Add second card + NVLink ($450)**
1. Buy matching Quadro RTX 5000 — ~$400
2. Buy NVLink HB Bridge 2-slot (part: P4934 / 1JF3K / 6FY12AA) — ~$50
3. Install second card in adjacent/nearby x16 slot
4. Connect NVLink bridge
5. Verify with `nvidia-smi nvlink --status`
6. Now running 32GB unified — Qwen3.5-35B-A3B at Q4_K_M with full 262K context

### Dell R720/R730 Installation Guide

#### Prerequisites (MUST HAVE before buying GPUs)

| Requirement | R720 | R730 | Why |
|-------------|-------|-------|-----|
| **Dual CPUs** | Required | Required | GPU riser slots are wired to CPU2 — dead without it |
| **2x 1100W PSUs** | Required | Required | 2x 230W GPUs + system = ~600W+ under load |
| **GPU Riser 3** | Required for 2nd GPU | Required for GPUs | Provides the PCIe x16 slot + 8-pin power |
| **GPU Power Cable** | Required | Required | Riser-to-GPU power, not included by default |
| **Low-Profile Heatsinks** | Must swap (part of enablement kit) | Usually pre-installed | Standard heatsinks block GPU riser clearance |
| **Max ambient temp** | 30°C (not the usual 35°C) | 30°C | High GPU TDP restricts cooling headroom |

#### Shopping List: Dell-Specific Parts

| Part | Dell P/N | What It Is | Price | Where |
|------|----------|------------|-------|-------|
| **GPU Power Cable** | **9H6FV** (09H6FV) | 8-pin EPS (riser) → 6-pin + 6+2-pin PCIe. One cable powers one GPU | ~$10-15 | Amazon, eBay |
| **GPU Power Cable (alt)** | **N08NH** (0N08NH) | Same function, alternate Dell part number | ~$10-15 | Amazon, eBay |
| **GPU Riser 3** (R720) | Check eBay for "R720 riser 3" or "R720 GPU riser" | Second riser card that provides GPU-capable x16 slot | ~$15-30 | eBay |
| **GPU Riser 3** (R730) | Check eBay for "R730 riser 3" or "R730 GPU riser" | R730 version — NOT interchangeable with R720 | ~$15-30 | eBay |
| **Low-Profile Heatsinks** (R720 only) | Part of original GPU enablement kit | Shorter heatsinks that clear the GPU riser. Search "R720 low profile heatsink" | ~$10-20/pair | eBay |

**You need 2x power cables** (one per GPU). Search Amazon for "Dell R720 R730 GPU power cable 9H6FV" — multiple sellers (COMeap, ZAHARA, BestParts) stock them for ~$10-15 each.

#### How It Fits

```
Dell R720/R730 Riser Layout (rear view):
┌─────────────────────────────────────┐
│  Riser 1          Riser 2    Riser 3│
│  (network/        (GPU 1)    (GPU 2)│
│   storage)        PCIe x16   PCIe x16│
│                   Gen2(720)  Gen2(720)│
│                   Gen3(730)  Gen3(730)│
└─────────────────────────────────────┘
         ↑ RTX 5000 ↑    ↑ RTX 5000 ↑
              └── NVLink Bridge ──┘
```

- Both GPUs sit on **adjacent risers** (Riser 2 + Riser 3) — this is 2-slot spacing
- The **2-slot NVLink bridge** (P4934) is the correct size for R720/R730
- The cards mount **vertically** via risers, parallel to each other
- NVLink bridge connects across the top of both cards

#### R720 vs R730

| Feature | R720 | R730 |
|---------|------|------|
| **PCIe** | Gen2 x16 | **Gen3 x16** |
| **Impact on LLM** | None — VRAM-bound | None — VRAM-bound |
| **Impact on NVLink** | None — NVLink bypasses PCIe | None — NVLink bypasses PCIe |
| **GPU power delivery** | Same 8-pin from riser | Same 8-pin from riser |
| **Heatsink swap** | Usually required | Usually already low-profile |
| **Used price** | ~$100-150 cheaper | Preferred if budget allows |
| **Recommendation** | Fine if you already have one | **Buy this one** if shopping new |

#### Potential Issues

1. **NVLink bridge clearance in 2U** — The bridge sits on top of both GPUs. In a 2U chassis
   this is tight. The R720/R730 riser design mounts cards vertically which actually helps —
   the bridge faces the chassis side panel, not the lid. Should fit, but measure before buying.

2. **Blower fan noise** — The RTX 5000 has an active blower (unlike passive Tesla cards).
   The server's own fans may spin higher to compensate. The blower exhausts out the bracket
   which is correct for rack airflow.

3. **"Unsupported" GPU warning** — Dell officially supports Tesla/Quadro cards from their era.
   The Quadro RTX 5000 is a later generation than R720/R730 was designed for, but community
   reports confirm Quadro RTX and even consumer RTX cards work fine. You won't get Dell support
   if something goes wrong, but electrically it's standard PCIe.

4. **CPU TDP limit** — Dell requires CPUs of 115W or less when GPUs are installed (R720).
   Check your CPU model. Most common Xeon E5-2600 v1/v2 (R720) and E5-2600 v3/v4 (R730)
   processors are within this range, but some high-core-count variants exceed it.

5. **PSU mode** — With dual 300W GPUs, set PSU configuration to **non-redundant mode**
   to use combined wattage from both PSUs. In redundant mode, you're limited to one PSU's
   capacity (1100W) which may not be enough under full GPU + CPU load.

#### Complete R720/R730 Shopping List

```
GPUS + NVLINK
  2x  Quadro RTX 5000                              ~$800
  1x  NVLink Bridge 2-slot (P4934 / L55997-001)    ~$50

DELL-SPECIFIC PARTS
  2x  GPU Power Cable (9H6FV or N08NH)             ~$25
  1x  GPU Riser 3 (match your server model!)       ~$20
  2x  Low-Profile Heatsinks (R720 only)            ~$15

POWER (if not already installed)
  2x  Dell 1100W PSU                               ~$30-50 ea

TOTAL (assuming you have the server + dual CPUs)    ~$940-960
```

## 24GB GPU Options (Previous Research — Still Valid for Tighter Budgets)

| GPU | VRAM | Price Range | Best Deals | Notes |
|-----|------|-------------|------------|-------|
| **Tesla P40** | 24GB | $150-320 | Newegg refurb $219-270; eBay used $150-200 | Best VRAM/$ at 24GB |
| **RTX A2000 12GB** | 12GB | $250-535 | eBay used ~$250-350; one listing at $490 | Can't run 32B models |
| **Tesla T4** | 16GB | $150-350 | eBay used $150-250 | Great power efficiency |
| **RTX A4000** | 16GB | $700-750+ | eBay used ~$700; new $720+ | Too expensive for 16GB |

## Rack Server Compatibility

### Quadro RTX 8000 Passive in R720/R730
- **Physical fit**: Full-length, dual-slot — fits in GPU riser slots
- **Power**: 260W, requires 8-pin aux power + GPU enablement kit
- **Cooling**: Passive — relies on server chassis fans (same as P40)
- **Requirement**: Dual CPUs, redundant 1100W PSUs recommended
- **NVLink**: Can pair two RTX 8000s for 96GB combined VRAM
- Very similar physical/power requirements to the Tesla P40

### RTX A2000 in R720/R730
- **Physical fit**: Yes. Dual-slot, low-profile, 167mm length
- **Power**: 70W bus-powered, no aux cable needed. Must use 75W slots (slots 4-7 on R720)
- **Cooling**: Blower-style fan exhausts out bracket — ideal for rack airflow
- **Requirement**: Dual CPUs needed for GPU PCIe slots
- **Confirmed working** in Dell R740XD (similar architecture)

### Tesla P40 in R720/R730
- **Physical fit**: Yes. Full-length, single-slot, designed for rack servers
- **Power**: 250W, requires 8-pin aux power. Needs GPU enablement kit
- **Cooling**: Passive — relies on server chassis fans
- **Requirement**: Dual CPUs, redundant 1100W PSUs recommended
- **Natively supported** in these servers

### R720 vs R730
- R720: PCIe Gen2 (not a bottleneck for LLM inference, which is VRAM-bound)
- R730: PCIe Gen3, generally preferred
- Both support up to 2x double-wide or 4x single-wide GPUs

## Recommended Setups

### If budget allows ($2,000–2,900): RTX 8000 Passive
Single card handles both coding and image gen. 48GB VRAM fits 32B models with massive
context windows (32K+). Passive cooling is rack-native. Tensor cores handle FP16 image gen
properly. One card, one slot, simple setup. The premium buys you unified VRAM = big context.

### If budget allows + dedicated image gen ($2,300–3,250): RTX 8000 + A2000
RTX 8000 for coding with full 48GB dedicated to LLM context.
A2000 for image gen (3x faster than Turing, 70W, bus-powered, blower cooled).
Best separation of concerns — no model swapping needed.

### Best value ($400–500): Dual P40
Two P40s for 48GB total, but split across cards (can't combine for one model without
NVLink, which P40s lack). One for 32B coding (tight fit, ~4K context), one for image gen
(slow, needs --force-fp32). **5x cheaper than RTX 8000** but with significant context limitations.

### Cheapest entry ($200–300): Single P40
Run 32B coding model with very limited context (~4K tokens). Swap to image gen when needed.
Good for testing whether local LLM coding works for your workflow before investing more.

## Configuration Notes for local-ai stack

### For 48GB RTX 8000
```bash
# Ollama — take advantage of the full 48GB
OLLAMA_NUM_GPU=999
OLLAMA_NUM_CTX=32768  # Large context window — 48GB can handle it
OLLAMA_KEEP_ALIVE=24h

# Pull best coding models
ollama pull qwen2.5-coder:32b-instruct-q4_K_M  # ~20GB, leaves 28GB for context
ollama pull qwen3.5:27b                          # ~16GB at Q4, even more context room
ollama pull qwen3-coder:30b                      # MoE, very fast inference

# Higher quantization for better quality (48GB allows this)
# Look for Q6_K or Q8_0 variants on Ollama for better output quality
```

### For 32B models on P40 (24GB — tight fit)
```bash
OLLAMA_NUM_GPU=999
OLLAMA_NUM_CTX=4096  # Keep context small to fit in remaining VRAM
OLLAMA_KEEP_ALIVE=24h

ollama pull qwen2.5-coder:32b-instruct-q4_K_M
```

### For dual-GPU setup (RTX 8000 + A2000 or P40 + anything)
```bash
# Assign GPU 0 to Ollama (coding), GPU 1 to InvokeAI (image gen)
# In docker-compose.yml for Ollama:
CUDA_VISIBLE_DEVICES=0

# In docker-compose.yml for InvokeAI:
CUDA_VISIBLE_DEVICES=1
```

### For image gen on P40 (no tensor cores)
```bash
# InvokeAI
INVOKEAI_PRECISION=float32

# ComfyUI launch args
--force-fp32
```

### For image gen on RTX 8000 / A2000 / T4 (has tensor cores)
```bash
# InvokeAI — native FP16 works fine
INVOKEAI_PRECISION=float16

# ComfyUI — no special flags needed
```

## Sources
- [Quadro RTX 8000 for Local LLMs — Hardware Corner](https://www.hardware-corner.net/guides/quadro-rtx-8000-for-llm/)
- [RTX 8000 Passive — Network Outlet](https://networkoutlet.com/blogs/articles/nvidia-quadro-rtx-8000-48gb-passive-cooling-powering-ai-rendering-server-workloads)
- [LLM Benchmarks on Turing/Ampere GPUs — Stefandroid](https://blog.stefandroid.com/2025/06/02/benchmark-llm-performance-nvidia-gpus.html)
- [NVIDIA A40 Price Tracking — GPUPoet](https://gpupoet.com/gpu/learn/card/nvidia-a40)
- [NVIDIA L40 Price Tracking — GPUPoet](https://gpupoet.com/gpu/learn/card/nvidia-l40)
- [RTX A6000 Price History — CamelCamelCamel](https://camelcamelcamel.com/product/B09BDH8VZV)
- [RTX A6000 Price History — Pangoly](https://pangoly.com/en/price-history/pny-nvidia-quadro-rtx-a6000)
- [NVIDIA RTX A2000 Datasheet](https://www.nvidia.com/content/dam/en-zz/Solutions/design-visualization/rtx-a2000/nvidia-rtx-a2000-datasheet-1987439-r5.pdf)
- [Dell R730 Owner's Manual — Expansion Cards](https://www.dell.com/support/manuals/en-us/poweredge-r730/r730_ompublication/expansion-card-installation-guidelines)
- [Dell R720 Owner's Manual — Expansion Cards](https://www.dell.com/support/manuals/en-us/poweredge-r720/720720xdom/expansion-card-installation-guidelines)
- [ComfyUI GPU Benchmarks Discussion](https://github.com/Comfy-Org/ComfyUI/discussions/2970)
- [ComfyUI P40 FP32 Issue](https://github.com/Comfy-Org/ComfyUI/issues/4363)
- [Best Local LLMs for 24GB VRAM 2026](https://localllm.in/blog/best-local-llms-24gb-vram)
- [Best Coding Models 2026](https://localvram.com/en/guides/best-coding-models/)
- [Ollama VRAM Requirements Guide](https://localllm.in/blog/ollama-vram-requirements-for-local-llms)
- [Local LLMs That Can Replace Claude Code](https://agentnativedev.medium.com/local-llms-that-can-replace-claude-code-6f5b6cac93bf)
- [7 Local LLM Families to Replace Claude/Codex](https://agentnativedev.medium.com/7-local-llm-families-to-replace-claude-codex-for-everyday-tasks-25ba74c3635d)
- [Qwen2.5-Coder 32B on Ollama](https://ollama.com/library/qwen2.5-coder:32b-instruct-q4_K_M)
- [Qwen3-Coder — How to Run Locally](https://unsloth.ai/docs/models/qwen3-coder-how-to-run-locally)

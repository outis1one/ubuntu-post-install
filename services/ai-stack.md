## Roles
- **Open WebUI** (chat, research, light coding) — local Ollama + any cloud providers
  in one model dropdown; wired to your code via the RAG + MCP servers and Gitea.
- **PaintPlus** (separate `paintplus` service) — the front end for all image work
  (inpaint / upscale / generate). Point its `AI_PROVIDER` at a cloud API, or at this
  stack's local `comfyui` / `invokeai` for local image-gen.
- **Gitea + GitHub sync** — `bash gitea-github-sync.sh` mirrors repos both ways
  (pull GitHub → local git, or push local → GitHub).
- **RAG / MCP / Kiwix** — retrieve just the relevant context so you feed the model
  less text (saves tokens), for both local and cloud models.
- Web search uses **DuckDuckGo** (no SearXNG in this build).

## Hybrid workflow — local coding model + Claude Code
Split coding work by size, not by tool preference. This stack's local Ollama
coder model (the GPU generations table below has sizing per card) handles
fast, in-loop iteration — autocomplete, boilerplate, single-file refactors,
private/offline drafting, zero token cost. Claude Code (cloud) handles the
bigger, longer, cross-file work — architectural refactors, anything needing
full-repo context or stronger judgment — driven against this stack's Gitea
(or GitHub, via the `gitea-github-sync.sh` mirror in Roles above).

### Where to put instructions for each side
Claude Code loads `CLAUDE.md` in four tiers, concatenated broadest to most
specific — later tiers add to earlier ones, they don't replace them:

| Tier | Path | Put here |
|---|---|---|
| User | `~/.claude/CLAUDE.md` | Your personal conventions, true on *every* project — e.g. "CLI menus are numbered, `0` is always exit," "verify UI changes with Playwright," your code-style rules |
| Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` | This codebase's own architecture/conventions, shared with collaborators via git (this file is the reference example) |
| Local | `./CLAUDE.local.md` (gitignored) | Your personal per-project notes — sandbox URLs, test data |
| One-off task | The prompt itself, handed over when you say "go" | The specific feature/idea for *this* build — never durable, don't put it in `CLAUDE.md` |

Write cross-project quirks into `~/.claude/CLAUDE.md` once — every project
inherits them automatically, no per-repo duplication needed. If it grows
past ~200 lines, split it into `~/.claude/rules/*.md` (still user-level,
loads before project-level rules).

### Claude Code reading from self-hosted Gitea
Two levels, depending on what you need:
- **Plain git — works today, nothing to install.** Claude Code's git
  operations are shell `git` commands, not a GitHub-specific code path —
  clone/push/pull against this stack's Gitea over SSH or an HTTPS token
  exactly like any other remote. This only applies to a locally-run Claude
  Code CLI against your own machine; a cloud/remote Claude Code session
  (like the one used to write this doc) is scoped to whichever provider —
  typically GitHub — it was attached to at session start, and can't reach
  an arbitrary self-hosted Gitea on your LAN.
- **PR/issue/CI-level integration (optional).** Reading/commenting on Gitea
  PRs and issues the way a GitHub MCP server does for GitHub needs an MCP
  server that speaks Gitea's REST API. Gitea's own project publishes one —
  `gitea/gitea-mcp` (gitea.com/gitea/gitea-mcp) — as a binary release, a
  Docker image (`docker.gitea.com/gitea-mcp-server`), or `go run
  gitea.com/gitea/gitea-mcp@latest`; it supports both stdio and HTTP
  transport. Generate a token first — this stack's Gitea → profile →
  Settings → Applications → Generate New Token (repo/api scopes) — then:
  ```bash
  # stdio — simplest, one Claude Code CLI on this box
  claude mcp add gitea --env GITEA_HOST=http://localhost:3001 \
      --env GITEA_ACCESS_TOKEN=<token> -- gitea-mcp -t stdio

  # or HTTP — one server, shared by multiple Claude Code clients
  gitea-mcp -t http --port 8090 &        # run once, e.g. alongside the stack
  claude mcp add gitea http://localhost:8090/mcp \
      --header "Authorization: Bearer <token>"
  ```
  Not bundled by default — this stack's Gitea has no built-in Claude
  integration out of the box; this is you adding it.

## GPU switcher (small local GPU only)
One small GPU can't run local chat and local image-gen at once. Swap it:
```bash
~/docker/ai-stack/gpu-mode.sh images   # before generating locally in PaintPlus
~/docker/ai-stack/gpu-mode.sh llm       # back to local chat in Open WebUI
~/docker/ai-stack/gpu-mode.sh status    # see which is active
```
Cloud models work anytime and need no swap.

## Service URLs
| Service    | URL                       | Auth                |
|------------|---------------------------|---------------------|
| Open WebUI | http://localhost:3000     | built-in (first visit = admin) |
| InvokeAI   | http://localhost:9090     | none                |
| ComfyUI    | http://localhost:8188     | none                |
| Kiwix      | http://localhost:8181     | none                |
| Gitea      | http://localhost:3001     | built-in            |
| Portainer  | https://localhost:9443    | built-in            |

## Manage the stack
```bash
cd ~/docker/ai-stack
bash start.sh          # pull latest images + docker compose up -d
bash stop.sh           # docker compose down
bash status.sh         # GPU / container / RAG health
bash pull-models.sh    # pull Ollama models (run once after first install)
```
Also a systemd unit: `sudo systemctl {start,stop,status} local-ai`

## Vision models (image understanding)
None of the tier-selected chat/code models above can read an image. `pull-models.sh`
offers one optional vision model at the end — pick it there, or pull one manually
any time:
```bash
docker exec ollama ollama pull moondream   # or llava:7b / qwen2.5vl:7b / llama3.2-vision:11b
```
| Model | Size | Notes |
|-------|------|-------|
| `moondream` | ~1.7 GB | By Moondream AI — tiny, built for CPU-only or weak/old-GPU hardware. Best default if you don't have a real GPU. |
| `llava:7b` | ~4.7 GB | General-purpose vision, moderate resources. |
| `qwen2.5vl:7b` | ~6 GB | Stronger accuracy, needs more RAM/VRAM. |
| `llama3.2-vision:11b` | ~7.9 GB | Meta's vision model — heaviest of these four. |

Point any OpenAI-compatible app's vision/image-import feature (e.g. Mealie's
"import recipe from photo") at this stack's Ollama endpoint with the pulled
model as `OPENAI_MODEL` — see Open WebUI → Settings → Connections for the
exact local base URL, or `docker inspect ollama` for the container's address
on `caddy_net`/the compose network.

## NVIDIA server-GPU generations — capability reference
What a given datacenter GPU generation can actually run through this stack
(Ollama for chat/code, ComfyUI/InvokeAI for images), since it's VRAM- and
tensor-core-bound per generation. Only Ampere and newer have native BF16
tensor cores; llama.cpp/Ollama's CUDA backend supports Pascal (compute
capability 6.0) and up, so quantized chat/coding model size mostly comes
down to VRAM capacity — older cards just run slower per token, with no
flash-attention-class kernel path.

| Generation | Example server cards | VRAM | Flux 2 (32B DiT) | Flux.1 / SDXL | Chat (GGUF, Ollama) | Coding (GGUF, Ollama) |
|---|---|---|---|---|---|---|
| Blackwell (2024-25) | B100 / B200 / GB200 | 180-192GB HBM3e | Yes — FP8 fast, native | Yes, fast | 70B+ at high precision, easily | Any coder model, full precision |
| Hopper (2022) | H100 / H200 | 80-141GB HBM3 | Yes — FP8 native tensor cores; the target generation | Yes, fast | 70B in Q4-Q8 comfortably | Qwen2.5-Coder-32B / DeepSeek-Coder-V2, full precision |
| Ampere (2020) | A100 40/80GB | 40-80GB HBM2e | Minimum viable — FP8 checkpoint (~32GB) fits the 80GB card; no native FP8 tensor cores, so it's upcast/emulated rather than accelerated | Yes, comfortable (native BF16/TF32) | 70B Q4 (~40GB) fits the 80GB card with room; 30-34B comfortable on the 40GB card | Qwen2.5-Coder-32B / Codestral-22B comfortable |
| Volta (2017) | V100 16/32GB | 16-32GB HBM2 | No — even the 32GB card has no headroom for the FP8 checkpoint plus activations | FLUX.1-dev FP8 (~18-23GB) fits the 32GB card, tight; SDXL/SD1.5 fine (first-gen FP16 tensor cores) | 32GB card: 30-34B Q4 comfortable, 70B tight/needs multi-GPU. 16GB card: 13-14B comfortable | 32B coder models fit the 32GB card in Q4 |
| Pascal (2016) | P100 16GB / P40 24GB | 16-24GB HBM2/GDDR5 | No | SD1.5 fine; SDXL runs but slow — no tensor cores at all, weak/emulated FP16 (worse on the P40 than the P100) | Same VRAM math as Ampere/Volta at matched capacity (P40 24GB ≈ 30B Q4), but noticeably slower tokens/sec | 32B coder Q4 fits the P40 24GB capacity-wise; fine for batch/background, not snappy interactive autocomplete |
| Maxwell (2014) | M40 / M60 24GB | 8-24GB GDDR5 | No | Impractical — SD1.5 only, very slow; no real FP16 tensor path | 7B-13B Q4 runs but slow | 7B-class coder models only — a novelty, not a daily driver |

**CUDA 13 has already dropped Pascal/Volta** (this happened, it's not a future
warning anymore) — but that's the *toolkit*, not the driver, and it doesn't
block this stack: Docker GPU passthrough only needs the host *driver* to
recognize the card, since prebuilt inference images (Ollama, ComfyUI, etc.)
already bundle whatever CUDA runtime they need internally. The driver is the
part to get right. **NVIDIA has named R580 the last driver branch that adds
Volta/Pascal support** (P100/P40/V100 explicitly listed), supported into
~June 2028 — pin to R580 explicitly rather than trusting `ubuntu-drivers
autoinstall`'s default pick on a fresh/newer Ubuntu install, since a later
branch may no longer initialize these cards at all. Also confirm you land on
the **proprietary** driver package, not an `-open` one — NVIDIA's open-source
kernel modules only support Turing and newer, so Volta/Pascal *require* the
closed-source module; `ubuntu-drivers devices` should recommend the right one
for the card it detects, but double-check rather than assume on a distro
release that defaults newer GPUs to `-open`. None of this is something
`require_docker` handles — it installs Docker/Compose only; the NVIDIA
driver and `nvidia-container-toolkit` are still on you to install first,
and getting the driver branch right is what actually matters here, not the
Ubuntu version itself.

**"Tesla"-branded card power connector — don't assume standard PCIe.**
("Tesla" here is NVIDIA's old datacenter-card *brand name*, retired after
Volta — not the unrelated, much older Tesla *microarchitecture* that
predates Fermi/Kepler/Maxwell/Pascal/Volta. V100/P100/P40/M40 all shipped
under the Tesla brand despite being four different architecture
generations.) These PCIe cards take an 8-pin **CPU/EPS12V** connector, not
the 6+2-pin PCIe
connector a normal GPU uses — a standard PCIe cable will not plug in. Get the
dongle/adapter (splits a PCIe 8-pin into EPS12V, or use a real EPS cable) and
never daisy-chain both 8-pin rails off one PSU cable/splitter — use two
separate cable runs. These cards are also passively cooled (built for server
chassis airflow, no onboard fan) — a tower case needs a shroud + dedicated
fan blowing through the heatsink fins, and there's no display output, which
is a non-issue on a headless box like this but worth knowing going in.

**MoE models are the exception that gives Pascal/Volta real life for coding.**
The "coding" column above assumes dense models, where token speed tracks the
full parameter count — exactly where Pascal/Volta's missing or first-gen
tensor cores hurt most. A mixture-of-experts model breaks that link: VRAM is
still set by *total* params (every expert has to be resident — no memory
saving from sparsity), but compute per token is set by *active* params only.
`qwen3-coder:30b-a3b` in `ollama pull` is the concrete case — 30B total, only
~3.3B active per token (128 experts, 8 routed) — so it needs the same ~19GB
VRAM (Q4_K_M) as a dense 30B model but computes like a dense ~3B one. That's
light enough that Pascal/Volta's weak tensor cores barely matter, making it
the best coding model to put on a P40 24GB or a V100 — a dense 32B coder on
the same card would be noticeably slower for no quality gain. Mixtral 8x7B
(46.7B total / ~13B active, ~24-26GB at Q4) is the same trade at a larger
size — fits Volta 32GB or Ampere, with the same active-vs-total gap.

## Cloud LLM providers (Open WebUI)
Open WebUI uses an OpenAI-compatible connection list. The local RAG server is the
first entry; any cloud providers added at install follow it. Two semicolon-separated
lists in `.env`, matched by position (RAG must stay first):
```bash
# ~/docker/ai-stack/.env
OPENAI_API_BASE_URLS=http://rag-server:8001/v1;https://api.groq.com/openai/v1
OPENAI_API_KEYS=local-rag;gsk_xxx
cd ~/docker/ai-stack && docker compose up -d open-webui   # apply
```
| Provider | Base URL | Key |
|----------|----------|-----|
| Groq | `https://api.groq.com/openai/v1` | https://console.groq.com/keys |
| DeepInfra | `https://api.deepinfra.com/v1/openai` | https://deepinfra.com/dash/api_keys |
| OpenAI | `https://api.openai.com/v1` | https://platform.openai.com/api-keys |
| OpenRouter | `https://openrouter.ai/api/v1` | https://openrouter.ai/keys |

Alternatively, add them at runtime in Open WebUI → Settings → Admin → Connections
(no file edits, survives image upgrades).

## Update
Re-run the `ai-stack` installer (refreshes vendored source, keeps your `.env`),
then `bash ~/docker/ai-stack/start.sh`. Or in place:
`cd ~/docker/ai-stack && bash local-ai-setup.sh --force`.

## Caddy
Open WebUI is reverse-proxied as `open-webui:8080` on `caddy_net` (or your
configured Caddy network name; attached with `docker network connect` after
start). Other services are LAN-only by default — add Caddy site blocks for
them if you want remote access.

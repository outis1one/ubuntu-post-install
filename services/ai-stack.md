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

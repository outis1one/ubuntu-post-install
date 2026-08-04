## Configure providers / keys
Edit `src/.env` then restart (the compose file interpolates these — no env_file):
```bash
cd ~/docker/paintplus/src
nano .env        # AI_PROVIDER, OPENAI_API_KEY / REPLICATE_API_KEY, HF_TOKEN
docker compose up -d --build
```
Keys: OpenAI https://platform.openai.com/api-keys · Replicate https://replicate.com/account/api-tokens

## Cloud mode (no GPU)
```bash
cd ~/docker/paintplus/src
docker compose up -d --build      # starts on http://localhost:3080
docker compose logs -f
docker compose down
```

## Local GPU mode (NVIDIA, ~13 GB of models)
```bash
cd ~/docker/paintplus/src
./install-local-gpu.sh            # toolkit + DNS fix + model prefetch
./bring-up-local-gpu.sh           # docker compose -f docker-compose.gpu.yml up -d --build
```
GPU auto-selects models by VRAM (FLUX >=24 GB, SDXL 12-24 GB, SD 1.5 <2 GB).

## ai-stack backend (no extra GPU download)
If the `ai-stack` service is installed on this box, PaintPlus can use its
InvokeAI/ComfyUI containers instead of the cloud or its own GPU installer —
select it during install, or switch later:
```bash
cd ~/docker/paintplus/src
nano .env        # AI_PROVIDER=invokeai (or comfyui), INVOKEAI_URL=http://invokeai:9090
docker network connect ai-stack_default paintplus   # one-time, if not already joined
docker compose up -d --build
```
PaintPlus reaches those containers by Docker network name, not localhost —
both must be on the same network (`ai-stack_default`, ai-stack's default).
If a small GPU is shared with ai-stack's local chat, swap to images first:
`~/docker/ai-stack/gpu-mode.sh images`.

## Update the app
Re-run the PaintPlus installer (copies the latest vendored source over `src/`,
keeping your `src/.env`), then rebuild:
```bash
cd ~/docker/paintplus/src && docker compose up -d --build
```

## Caddy
Reverse-proxied as `paintplus:8000` on `caddy_net` (or your configured Caddy
network name). Cloud mode joins that network via
`src/docker-compose.override.yml`; GPU mode is attached with `docker network
connect` after start. Same for the ai-stack backend — attached to
`ai-stack_default` with `docker network connect` after start.

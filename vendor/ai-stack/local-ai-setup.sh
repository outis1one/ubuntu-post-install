#!/usr/bin/env bash
# Local AI Stack — single script, new install or update
# Usage: ./local-ai-setup.sh [--force] [--no-pull]
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[..]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[!!]${NC}  $*"; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

FORCE=false; NO_PULL=false
for a in "$@"; do [[ "$a" == "--force" ]] && FORCE=true; [[ "$a" == "--no-pull" ]] && NO_PULL=true; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR"
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')
[[ -z "$LOCAL_IP" ]] && read -rp "Enter LAN IP: " LOCAL_IP

IS_UPDATE=false; [[ -f "$BASE/docker-compose.yml" ]] && IS_UPDATE=true

# ── detect VRAM and set models accordingly ────────────────────────────────────
VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
          | head -1 | awk '{printf "%d", $1/1024}' 2>/dev/null || echo "0")
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo "0")
TOTAL_VRAM=$((VRAM_GB * GPU_COUNT))

# Ollama optimization flags (stacked — see docs/gpu-setup-research.md)
OLLAMA_KV_CACHE="q8_0"          # halves KV cache VRAM (q4_0 for aggressive)
OLLAMA_FLASH="1"                # flash attention: less VRAM, no quality loss

if   [[ "$TOTAL_VRAM" -ge 40 ]]; then
    CHAT_MODEL="qwen3.5:27b";  CODE_MODEL="qwen3.5:27b"
    CTX=131072; TIER="${TOTAL_VRAM}GB — 27B dense, 128K context"
elif [[ "$TOTAL_VRAM" -ge 28 ]]; then
    CHAT_MODEL="qwen3.5-35b-a3b";  CODE_MODEL="qwen3.5-35b-a3b"
    CTX=131072; TIER="${TOTAL_VRAM}GB — 35B MoE, 128K context"
elif [[ "$TOTAL_VRAM" -ge 14 ]]; then
    CHAT_MODEL="qwen3.5-35b-a3b";  CODE_MODEL="qwen3.5-35b-a3b"
    CTX=65536;  TIER="${TOTAL_VRAM}GB — 35B MoE + KV quant, 64K context"
elif [[ "$TOTAL_VRAM" -ge 8 ]]; then
    CHAT_MODEL="qwen3.5:9b";  CODE_MODEL="qwen3.5:9b"
    CTX=32768;  TIER="${TOTAL_VRAM}GB — 9B dense, 32K context"
elif [[ "$TOTAL_VRAM" -ge 6 ]]; then
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=32768;  TIER="${TOTAL_VRAM}GB — 4B + KV quant, 32K context"
elif [[ "$TOTAL_VRAM" -ge 4 ]]; then
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=16384;  TIER="${TOTAL_VRAM}GB — 4B models, 16K context"
else
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=4096;   OLLAMA_KV_CACHE="q4_0"; TIER="CPU-only — 4B models, 4K context"
fi
EMBED_MODEL="nomic-embed-text"

# ── Image generation model tiers (VRAM-aware) ────────────────────────────────
# These vars are used by setup-image-models.sh and printed in status output.
# Image gen shares GPU with Ollama — Ollama unloads after KEEP_ALIVE timeout,
# so image gen gets full VRAM when Ollama is idle.
if   [[ "$TOTAL_VRAM" -ge 24 ]]; then
    IMG_MODELS="SD 1.5, SDXL, SDXL Turbo, Flux.1-dev, Flux.1-schnell"
    IMG_TIER="all models including Flux"
    IMG_DEFAULT="SDXL"
elif [[ "$TOTAL_VRAM" -ge 12 ]]; then
    IMG_MODELS="SD 1.5, SDXL, SDXL Turbo, Flux.1-schnell (tight)"
    IMG_TIER="SDXL + Flux-schnell"
    IMG_DEFAULT="SDXL"
elif [[ "$TOTAL_VRAM" -ge 8 ]]; then
    IMG_MODELS="SD 1.5, SDXL (tight at 512px), SDXL Turbo"
    IMG_TIER="SD 1.5 comfortable, SDXL possible"
    IMG_DEFAULT="SD 1.5"
elif [[ "$TOTAL_VRAM" -ge 4 ]]; then
    IMG_MODELS="SD 1.5 (float16)"
    IMG_TIER="SD 1.5 only"
    IMG_DEFAULT="SD 1.5"
else
    IMG_MODELS="none (CPU generation extremely slow)"
    IMG_TIER="CPU only — not recommended"
    IMG_DEFAULT=""
fi

# ── InvokeAI precision (GPU-aware) ───────────────────────────────────────────
GPU_COMPUTE=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
              | head -1 | tr -d '.' || echo "0")
if   [[ "$GPU_COMPUTE" -ge 80 ]]; then
    INVOKEAI_PRECISION="bfloat16"   # Ampere+ (RTX 30xx/40xx/50xx, A-series)
elif [[ "$GPU_COMPUTE" -ge 60 ]]; then
    INVOKEAI_PRECISION="float16"    # Pascal+ (GTX 10xx, RTX 20xx, Tesla P40/V100)
else
    INVOKEAI_PRECISION="auto"       # Let InvokeAI decide
fi

section "Local AI Stack — $($IS_UPDATE && echo UPDATE || echo NEW INSTALL)"
info "Base    : $BASE"
info "IP      : $LOCAL_IP"
info "GPU     : ${VRAM_GB}GB VRAM → $TIER"
info "Image   : $IMG_TIER ($IMG_MODELS)"


write_if_new() {
    local dest="$1"; local body; body=$(cat)
    if [[ ! -f "$dest" ]] || $FORCE; then
        printf '%s\n' "$body" > "$dest"; ok "Wrote   $(basename "$dest")"
    else
        info "Kept    $(basename "$dest")  (--force to overwrite)"
    fi
}

# ── prereqs (new install only) ────────────────────────────────────────────────
if ! $IS_UPDATE; then
  section "Prerequisites"
  if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Run: newgrp docker  (or log out/in)"
  else
    ok "Docker: $(docker --version | cut -d' ' -f3)"
  fi

  if command -v nvidia-smi &>/dev/null && ! dpkg -l 2>/dev/null | grep -q nvidia-container-toolkit; then
    info "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update -qq && sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
    ok "NVIDIA Container Toolkit installed"
  fi
  command -v rg &>/dev/null || sudo apt-get install -y ripgrep
fi

# ── directories ───────────────────────────────────────────────────────────────
section "Directories"
for d in papers repos workspace index invokeai-data invokeai-outputs comfyui-data comfyui-output kiwix gitea portainer-data logs; do
    mkdir -p "$BASE/$d"
done
ok "Ready under $BASE"

# =============================================================================
section "Writing server.py (RAG)"
# =============================================================================
write_if_new "$BASE/server.py" << 'PY'
import ast, fnmatch, hashlib, json, logging, os, re, subprocess, threading, time
from pathlib import Path
from typing import Any
import chromadb, httpx
from chromadb.utils.embedding_functions import OllamaEmbeddingFunction
from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rag")

OLLAMA_URL  = os.getenv("OLLAMA_URL",  "http://ollama:11434")
CHROMA_URL  = os.getenv("CHROMA_URL",  "http://chromadb:8000")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
CHAT_MODEL  = os.getenv("CHAT_MODEL",  "qwen2.5:14b")
PAPERS_DIR  = Path(os.getenv("PAPERS_DIR", "/papers"))
REPOS_DIR   = Path(os.getenv("REPOS_DIR",  "/repos"))
TOP_K       = int(os.getenv("TOP_K", "6"))

CODE_EXTS  = {".py",".js",".ts",".tsx",".jsx",".go",".rs",".java",".c",".cpp",
              ".h",".cs",".rb",".sh",".yaml",".yml",".toml",".sql",".md"}
SKIP_DIRS  = {"node_modules",".git","__pycache__","dist","build",".venv","venv","target"}
MAX_BYTES  = 400_000

app = FastAPI(title="RAG Server")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

def _embed_fn():
    return OllamaEmbeddingFunction(url=f"{OLLAMA_URL}/api/embeddings", model_name=EMBED_MODEL)

def _chroma():
    host, port = CHROMA_URL.replace("http://","").split(":")
    return chromadb.HttpClient(host=host, port=int(port))

def get_col(name):
    return _chroma().get_or_create_collection(name, embedding_function=_embed_fn())

def _doc_id(text, key):
    return hashlib.md5(f"{key}|{text[:200]}".encode()).hexdigest()

def _sliding(text, size=1000, overlap=150):
    chunks, i = [], 0
    while i < len(text):
        chunks.append(text[i:i+size]); i += size - overlap
    return [c for c in chunks if c.strip()]

def _chunk_python(src):
    try: tree = ast.parse(src)
    except SyntaxError: return []
    lines = src.splitlines(); out = []
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            out.append((node.name, "\n".join(lines[node.lineno-1:node.end_lineno])[:4000]))
    return out

def _chunk_file(path, src):
    if path.suffix == ".py":
        pairs = _chunk_python(src)
        if pairs: return pairs
    pat = re.compile(r'(?:^|\n)(?=(?:export\s+)?(?:async\s+)?(?:function|class)|^func |^type |^impl |^pub fn |^fn )', re.M)
    parts = [p.strip() for p in pat.split(src) if p.strip()]
    if len(parts) > 1: return [(f"s{i}", p[:4000]) for i,p in enumerate(parts)]
    return [(f"c{i}", c) for i,c in enumerate(_sliding(src, 1200, 200))]

def ingest_file(col, fpath, repo=""):
    if fpath.stat().st_size > MAX_BYTES: return
    if any(fnmatch.fnmatch(fpath.name, p) for p in ("*.min.js","*.map","package-lock.json","yarn.lock")): return
    try: src = fpath.read_text(encoding="utf-8", errors="ignore")
    except: return
    if not src.strip(): return
    rel = str(fpath)
    pairs = _chunk_file(fpath, src) if fpath.suffix in CODE_EXTS else \
            [(f"c{i}",c) for i,c in enumerate(_sliding(src))]
    ids,docs,metas = [],[],[]
    for label,chunk in pairs:
        if not chunk.strip(): continue
        ids.append(_doc_id(chunk, rel+label)); docs.append(chunk)
        metas.append({"source":rel,"label":label,"repo":repo,"lang":fpath.suffix.lstrip(".")})
    if ids: col.upsert(ids=ids, documents=docs, metadatas=metas)

def ingest_dir(col, directory, repo=""):
    count = 0
    for f in directory.rglob("*"):
        if not f.is_file() or any(p in f.parts for p in SKIP_DIRS): continue
        ingest_file(col, f, repo); count += 1
    log.info("Indexed %d files from %s", count, directory); return count

def ingest_pdfs(col):
    try: import pypdf
    except ImportError: return 0
    n = 0
    for pdf in PAPERS_DIR.glob("*.pdf"):
        try:
            text = "\n".join(p.extract_text() or "" for p in pypdf.PdfReader(str(pdf)).pages)
            for i,chunk in enumerate(_sliding(text)):
                col.upsert(ids=[_doc_id(chunk,str(pdf)+str(i))], documents=[chunk],
                           metadatas=[{"source":str(pdf),"label":f"p{i}","repo":"","lang":"pdf"}])
            n += 1
        except Exception as e: log.warning("PDF %s: %s", pdf.name, e)
    return n

def _startup():
    for _ in range(40):
        try:
            r = httpx.get(f"{OLLAMA_URL}/api/tags", timeout=5)
            if any(EMBED_MODEL in m["name"] for m in r.json().get("models",[])): break
        except: pass
        log.info("Waiting for embed model..."); time.sleep(5)
    code_col = get_col("code"); papers_col = get_col("papers")
    for d in REPOS_DIR.iterdir():
        if d.is_dir(): ingest_dir(code_col, d, d.name)
    ingest_pdfs(papers_col)
    for f in PAPERS_DIR.glob("*.txt"): ingest_file(papers_col, f)
    log.info("Startup index done")

@app.on_event("startup")
async def on_startup(): threading.Thread(target=_startup, daemon=True).start()

@app.get("/health")
async def health():
    try:
        cc = _chroma()
        return {"status":"ok",
                "code":   cc.get_collection("code",   embedding_function=_embed_fn()).count(),
                "papers": cc.get_collection("papers", embedding_function=_embed_fn()).count()}
    except Exception as e: return {"status":"error","detail":str(e)}

class RepoReq(BaseModel):
    url: str; name: str = ""; branch: str = "main"

@app.post("/ingest/repo")
async def ingest_repo(req: RepoReq):
    name = req.name or req.url.rstrip("/").split("/")[-1].removesuffix(".git")
    dest = REPOS_DIR / name
    try:
        if dest.exists(): subprocess.run(["git","pull"], cwd=dest, check=True, timeout=120)
        else: subprocess.run(["git","clone","--depth=1","-b",req.branch,req.url,str(dest)], check=True, timeout=300)
    except subprocess.CalledProcessError as e: raise HTTPException(400, str(e))
    return {"status":"ok","repo":name,"files":ingest_dir(get_col("code"),dest,name)}

@app.post("/ingest/papers")
async def trigger_papers(bg: BackgroundTasks):
    bg.add_task(ingest_pdfs, get_col("papers")); return {"status":"queued"}

async def _webhook(payload):
    repo = payload.get("repository") or {}
    url = repo.get("clone_url") or repo.get("html_url",""); name = repo.get("name","unknown")
    if not url: return {"status":"ignored"}
    dest = REPOS_DIR / name
    if dest.exists(): subprocess.run(["git","pull"], cwd=dest, timeout=120)
    else: subprocess.run(["git","clone","--depth=1",url,str(dest)], timeout=300)
    return {"status":"ok","repo":name,"files":ingest_dir(get_col("code"),dest,name)}

@app.post("/webhook/gitea")
async def wh_gitea(r: Request): return await _webhook(await r.json())
@app.post("/webhook/github")
async def wh_github(r: Request): return await _webhook(await r.json())

def _ctx(query, cols):
    parts = []
    for cn in cols:
        try:
            col = get_col(cn)
            if col.count() == 0: continue
            res = col.query(query_texts=[query], n_results=min(TOP_K, col.count()))
            for doc,meta in zip(res["documents"][0], res["metadatas"][0]):
                parts.append(f"### {meta.get('source','')}:{meta.get('label','')}\n```{meta.get('lang','')}\n{doc}\n```")
        except Exception as e: log.warning("col %s: %s", cn, e)
    return "\n\n".join(parts)

class ChatReq(BaseModel):
    model: str = CHAT_MODEL; messages: list[dict[str,Any]]
    stream: bool = False; collections: list[str] = ["code","papers"]

@app.post("/v1/chat/completions")
async def chat(req: ChatReq):
    query = next((m["content"] for m in reversed(req.messages) if m.get("role")=="user"), "")
    ctx = _ctx(query, req.collections)
    msgs = [{"role":"system","content":f"You are a coding assistant. Use context below.\n\n## Context\n{ctx}"}] + req.messages
    payload = {"model":req.model,"messages":msgs,"stream":req.stream}
    if req.stream:
        async def gen():
            async with httpx.AsyncClient(timeout=300) as c:
                async with c.stream("POST",f"{OLLAMA_URL}/v1/chat/completions",json=payload) as r:
                    async for chunk in r.aiter_bytes(): yield chunk
        return StreamingResponse(gen(), media_type="text/event-stream")
    async with httpx.AsyncClient(timeout=300) as c:
        r = await c.post(f"{OLLAMA_URL}/v1/chat/completions", json=payload)
    return r.json()

if __name__ == "__main__":
    import uvicorn; uvicorn.run("server:app", host="0.0.0.0", port=8001, reload=False)
PY

# =============================================================================
section "Writing mcp_server.py"
# =============================================================================
write_if_new "$BASE/mcp_server.py" << 'PY'
import json, os, re, subprocess
from pathlib import Path
import httpx
from mcp.server.fastmcp import FastMCP

WORKSPACE    = Path(os.getenv("WORKSPACE_DIR", "/workspace"))
REPOS_DIR    = Path(os.getenv("REPOS_DIR",     "/repos"))
GITEA_URL    = os.getenv("GITEA_URL",   "http://gitea:3000")
GITEA_TOKEN  = os.getenv("GITEA_TOKEN", "")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN","")
RAG_URL      = os.getenv("RAG_URL",     "http://rag-server:8001")

mcp = FastMCP("local-dev-tools")

@mcp.tool()
def bash(command: str, cwd: str = "") -> str:
    """Run a shell command. Default cwd is /workspace."""
    work = Path(cwd) if cwd else WORKSPACE
    work.mkdir(parents=True, exist_ok=True)
    try:
        r = subprocess.run(command, shell=True, cwd=work, timeout=120, capture_output=True, text=True)
        out = r.stdout + (f"\n[stderr]\n{r.stderr}" if r.stderr else "")
        if r.returncode != 0: out += f"\n[exit {r.returncode}]"
        return out or "(no output)"
    except subprocess.TimeoutExpired: return "[timeout]"
    except Exception as e: return f"[error] {e}"

@mcp.tool()
def read_file(path: str) -> str:
    """Read a file. Absolute or relative to /workspace."""
    p = Path(path) if Path(path).is_absolute() else WORKSPACE / path
    if not p.exists(): return f"[not found] {p}"
    if p.stat().st_size > 500_000: return f"[too large: {p.stat().st_size//1024}KB]"
    return p.read_text(encoding="utf-8", errors="replace")

@mcp.tool()
def write_file(path: str, content: str) -> str:
    """Write content to a file. Relative to /workspace."""
    p = Path(path) if Path(path).is_absolute() else WORKSPACE / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"Wrote {len(content)} chars to {p}"

@mcp.tool()
def list_files(path: str = "", pattern: str = "**/*") -> str:
    """List files matching a glob pattern."""
    base = Path(path) if path else WORKSPACE
    if not base.exists(): return f"[not found] {base}"
    files = sorted(str(f.relative_to(base)) for f in base.glob(pattern) if f.is_file())
    return "\n".join(files[:500]) or "(empty)"

@mcp.tool()
def search_code(query: str, path: str = "", glob: str = "", case_sensitive: bool = False) -> str:
    """Search file contents with ripgrep."""
    base = path or str(WORKSPACE)
    cmd = ["rg", "--line-number", "--no-heading"]
    if not case_sensitive: cmd.append("-i")
    if glob: cmd += ["-g", glob]
    cmd += [query, base]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        lines = r.stdout.strip().splitlines()
        if len(lines) > 200: lines = lines[:200] + [f"...({len(r.stdout.splitlines())-200} more)"]
        return "\n".join(lines) or "(no matches)"
    except FileNotFoundError:
        r = subprocess.run(["grep","-rn",query,base], capture_output=True, text=True, timeout=30)
        return r.stdout[:8000] or "(no matches)"

@mcp.tool()
def fetch_url(url: str, extract_text: bool = True) -> str:
    """Fetch the content of a URL."""
    try:
        r = httpx.get(url, timeout=30, follow_redirects=True, headers={"User-Agent":"Mozilla/5.0"})
        content = r.text
        if extract_text:
            content = re.sub(r'<script[^>]*>.*?</script>', '', content, flags=re.DOTALL)
            content = re.sub(r'<style[^>]*>.*?</style>',  '', content, flags=re.DOTALL)
            content = re.sub(r'<[^>]+>', '', content)
            content = re.sub(r'\n{3,}', '\n\n', content).strip()
        return content[:20000]
    except Exception as e: return f"[error] {e}"

def _git(args, repo=""):
    cwd = Path(repo) if repo else WORKSPACE
    r = subprocess.run(["git"]+args, cwd=cwd, capture_output=True, text=True, timeout=60)
    return (r.stdout + r.stderr).strip() or "(no output)"

@mcp.tool()
def git_status(repo: str = "") -> str:
    """Show git status."""
    return _git(["status","--short"], repo)

@mcp.tool()
def git_diff(repo: str = "", cached: bool = False) -> str:
    """Show git diff."""
    flag = ["--cached"] if cached else []
    return _git(["diff","--stat"]+flag, repo) + "\n\n" + _git(["diff"]+flag, repo)

@mcp.tool()
def git_log(repo: str = "", n: int = 10) -> str:
    """Show last n commits."""
    return _git(["log",f"-{n}","--oneline","--decorate"], repo)

@mcp.tool()
def git_commit(message: str, repo: str = "", add_all: bool = True) -> str:
    """Stage all and commit."""
    if add_all: _git(["add","-A"], repo)
    return _git(["commit","-m",message], repo)

@mcp.tool()
def git_checkout(branch: str, repo: str = "", create: bool = False) -> str:
    """Checkout or create a branch."""
    return _git(["checkout","-b",branch] if create else ["checkout",branch], repo)

def _gitea(method, path, body=None):
    if not GITEA_TOKEN: return {"error":"GITEA_TOKEN not set in .env"}
    r = httpx.request(method, f"{GITEA_URL}/api/v1{path}",
                      json=body, headers={"Authorization":f"token {GITEA_TOKEN}"}, timeout=30)
    try: return r.json()
    except: return {"status":r.status_code,"text":r.text}

@mcp.tool()
def gitea_list_repos() -> str:
    """List your Gitea repos."""
    d = _gitea("GET", "/repos/search?limit=50")
    if "error" in d: return d["error"]
    return "\n".join(f"{r['full_name']} — {r.get('description','')}" for r in d.get("data",[]))

@mcp.tool()
def gitea_create_repo(name: str, private: bool = True, description: str = "") -> str:
    """Create a Gitea repo."""
    r = _gitea("POST","/user/repos",{"name":name,"private":private,"description":description,"auto_init":True,"default_branch":"main"})
    return r.get("html_url") or str(r)

@mcp.tool()
def gitea_create_issue(repo: str, title: str, body: str = "") -> str:
    """Create a Gitea issue (owner/repo)."""
    r = _gitea("POST",f"/repos/{repo}/issues",{"title":title,"body":body})
    return r.get("html_url") or str(r)

@mcp.tool()
def github_api(method: str, endpoint: str, body: str = "") -> str:
    """Call GitHub REST API. endpoint e.g. /repos/owner/repo/issues"""
    if not GITHUB_TOKEN: return "GITHUB_TOKEN not set in .env"
    r = httpx.request(method.upper(), f"https://api.github.com{endpoint}",
                      json=json.loads(body) if body else None,
                      headers={"Authorization":f"Bearer {GITHUB_TOKEN}","Accept":"application/vnd.github+json"},
                      timeout=30)
    try: return json.dumps(r.json(), indent=2)
    except: return r.text

@mcp.tool()
def ingest_repo(url: str, name: str = "", branch: str = "main") -> str:
    """Clone a repo and index it in RAG."""
    r = httpx.post(f"{RAG_URL}/ingest/repo", json={"url":url,"name":name,"branch":branch}, timeout=300)
    return r.text

@mcp.tool()
def rag_health() -> str:
    """Check RAG server status."""
    try: return httpx.get(f"{RAG_URL}/health", timeout=10).text
    except Exception as e: return f"RAG unreachable: {e}"

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(mcp.sse_app(), host="0.0.0.0", port=8002)
PY

# =============================================================================
section "Requirements"
# =============================================================================
cat > "$BASE/requirements.txt" << 'REQ'
fastapi
uvicorn[standard]
httpx
pydantic
chromadb
pypdf
python-multipart
REQ

cat > "$BASE/mcp_requirements.txt" << 'REQ'
mcp[cli]
fastapi
uvicorn[standard]
httpx
duckduckgo-search
REQ
ok "requirements.txt + mcp_requirements.txt"

# =============================================================================
section ".env (tokens — never overwritten)"
# =============================================================================
if [[ ! -f "$BASE/.env" ]]; then
    cat > "$BASE/.env" << ENV
# Local AI Stack — edit to add your API tokens
GITEA_TOKEN=your-gitea-token-here
GITHUB_TOKEN=your-github-token-here
GITEA_URL=http://$LOCAL_IP:3001
ENV
    ok "Created .env"
else
    info "Kept .env"
fi

# =============================================================================
section "Docker Compose"
# =============================================================================
cat > "$BASE/docker-compose.yml" << COMPOSE
# Local AI Stack — generated $(date '+%Y-%m-%d')
# GPU: OLLAMA_NUM_GPU=999 uses all available VRAM automatically (V100/RTX/any)
# Context: OLLAMA_NUM_CTX= set by detected VRAM (GB)
#
# ── Common commands (run from this folder) ─────────────────────────────────────
# Start everything:          docker compose up -d
# Stop everything:           docker compose down
# Restart one service:       docker compose restart <service>
# Stop one service:          docker compose stop <service>
# Start one service:         docker compose up -d <service>
# Follow all logs:           docker compose logs -f
# Follow one service logs:   docker compose logs -f <service>
# Pull latest images:        docker compose pull && docker compose up -d
# Show status:               docker compose ps
#
# Services: ollama  open-webui  chromadb  rag-server  mcp-server  aider
#           kiwix  gitea  invokeai  portainer
# ───────────────────────────────────────────────────────────────────────────────

services:

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports: ["0.0.0.0:11434:11434"]
    volumes: [ollama-models:/root/.ollama]
    environment:
      - OLLAMA_NUM_GPU=999
      - OLLAMA_NUM_CTX=$CTX
      - OLLAMA_KEEP_ALIVE=24h
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_KV_CACHE_TYPE=$OLLAMA_KV_CACHE
      - OLLAMA_FLASH_ATTENTION=$OLLAMA_FLASH
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD","ollama","list"]
      interval: 30s; timeout: 10s; retries: 5

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports: ["0.0.0.0:3000:8080"]
    volumes: [open-webui-data:/app/backend/data]
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - OPENAI_API_BASE_URL=http://rag-server:8001/v1
      - OPENAI_API_KEY=local-rag
      - ENABLE_OPENAI_API=true
      - ENABLE_TOOL_SERVERS=true
      - WEBUI_AUTH=true
      - ENABLE_RAG_WEB_SEARCH=true
      - RAG_WEB_SEARCH_ENGINE=duckduckgo
      - ENABLE_IMAGE_GENERATION=true
      - IMAGE_GENERATION_ENGINE=comfyui
      - COMFYUI_BASE_URL=http://comfyui:8188
    depends_on:
      ollama: {condition: service_healthy}

  chromadb:
    image: chromadb/chroma:latest
    container_name: chromadb
    restart: unless-stopped
    ports: ["0.0.0.0:8000:8000"]
    volumes: [$BASE/index:/chroma/chroma]
    environment:
      - IS_PERSISTENT=TRUE
      - ANONYMIZED_TELEMETRY=FALSE
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:8000/api/v2/heartbeat || exit 1"]
      interval: 15s; timeout: 5s; retries: 5

  rag-server:
    image: python:3.11-slim
    container_name: rag-server
    restart: unless-stopped
    ports: ["0.0.0.0:8001:8001"]
    volumes:
      - $BASE/papers:/papers
      - $BASE/repos:/repos
      - $BASE/index:/index
      - $BASE/server.py:/app/server.py
      - $BASE/requirements.txt:/app/requirements.txt
    working_dir: /app
    environment:
      - OLLAMA_URL=http://ollama:11434
      - CHROMA_URL=http://chromadb:8000
      - EMBED_MODEL=nomic-embed-text
      - CHAT_MODEL=$CHAT_MODEL
    command: >
      bash -c "apt-get update -qq && apt-get install -y --no-install-recommends git &&
               pip install --no-cache-dir -r requirements.txt &&
               uvicorn server:app --host 0.0.0.0 --port 8001"
    depends_on:
      chromadb: {condition: service_healthy}
      ollama:   {condition: service_healthy}

  mcp-server:
    image: python:3.11-slim
    container_name: mcp-server
    restart: unless-stopped
    ports: ["0.0.0.0:8002:8002"]
    volumes:
      - $BASE/workspace:/workspace
      - $BASE/repos:/repos
      - $BASE/mcp_server.py:/app/mcp_server.py
      - $BASE/mcp_requirements.txt:/app/mcp_requirements.txt
      - $SCRIPT_DIR/gitea-github-sync.sh:/app/gitea-github-sync.sh:ro
    working_dir: /app
    env_file: $BASE/.env
    environment:
      - WORKSPACE_DIR=/workspace
      - REPOS_DIR=/repos
      - GITEA_URL=http://gitea:3000
      - RAG_URL=http://rag-server:8001
      - KIWIX_URL=http://kiwix:80
    command: >
      bash -c "apt-get update -qq && apt-get install -y --no-install-recommends git ripgrep curl &&
               pip install --no-cache-dir -r mcp_requirements.txt &&
               python mcp_server.py"
    depends_on: [rag-server, kiwix]

  aider:
    image: paulgauthier/aider:latest
    container_name: aider
    restart: unless-stopped
    ports: ["0.0.0.0:8080:8501"]
    volumes:
      - $BASE/workspace:/workspace
      - $BASE/repos:/repos
    working_dir: /workspace
    environment:
      - OLLAMA_API_BASE=http://ollama:11434
      - GIT_AUTHOR_NAME=aider
      - GIT_AUTHOR_EMAIL=aider@local
      - GIT_COMMITTER_NAME=aider
      - GIT_COMMITTER_EMAIL=aider@local
    command: >
      --gui --no-auto-commits --no-check-update
      --model ollama/$CODE_MODEL
    depends_on:
      ollama: {condition: service_healthy}

  kiwix:
    image: ghcr.io/kiwix/kiwix-serve:latest
    container_name: kiwix
    restart: unless-stopped
    ports: ["0.0.0.0:8181:80"]
    volumes: [$BASE/kiwix:/data]
    entrypoint: ["sh", "-c"]
    command: ["ls /data/*.zim >/dev/null 2>&1 && exec kiwix-serve /data/*.zim || { echo 'No ZIM files in /data yet - sleeping. Add .zim files and restart kiwix.'; exec sleep infinity; }"]

  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    restart: unless-stopped
    ports: ["0.0.0.0:3001:3000","0.0.0.0:2222:22"]
    volumes:
      - $BASE/gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__database__PATH=/data/gitea/gitea.db
      - GITEA__webhook__ALLOWED_HOST_LIST=rag-server,mcp-server

  invokeai:
    image: ghcr.io/invoke-ai/invokeai:latest
    container_name: invokeai
    restart: unless-stopped
    ports: ["0.0.0.0:9090:9090"]
    volumes:
      - invokeai-models:/invokeai/models
      - $BASE/invokeai-outputs:/invokeai/outputs
      - $BASE/invokeai-data:/invokeai/databases
    environment:
      - INVOKEAI_HOST=0.0.0.0
      - INVOKEAI_PORT=9090
      - INVOKEAI_PRECISION=$INVOKEAI_PRECISION
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  comfyui:
    image: ghcr.io/ai-dock/comfyui:latest
    container_name: comfyui
    restart: unless-stopped
    ports: ["0.0.0.0:8188:8188"]
    volumes:
      - comfyui-models:/opt/ComfyUI/models
      - $BASE/comfyui-output:/opt/ComfyUI/output
      - $BASE/comfyui-data:/opt/ComfyUI/custom_nodes
    environment:
      - CLI_ARGS=--listen 0.0.0.0
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports: ["0.0.0.0:9000:9000","0.0.0.0:9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $BASE/portainer-data:/data

volumes:
  ollama-models:
  open-webui-data:
  invokeai-models:
  comfyui-models:
COMPOSE
ok "docker-compose.yml"

# =============================================================================
section "Firewall"
# =============================================================================
if command -v ufw &>/dev/null && [[ ! -f "$BASE/.ufw-done" ]] || $FORCE; then
    read -rp "  LAN subnet [192.168.1.0/24]: " LAN; LAN="${LAN:-192.168.1.0/24}"
    [[ "$LAN" =~ /[0-9]+$ ]] || LAN="${LAN}/24"
    for pc in "3000:Open WebUI" "11434:Ollama" "8001:RAG" "8002:MCP" \
              "8000:ChromaDB" "8080:Aider" "8181:Kiwix" \
              "3001:Gitea" "2222:Gitea SSH" "9090:InvokeAI" "8188:ComfyUI" \
              "9000:Portainer" "9443:Portainer S"; do
        sudo ufw allow from "$LAN" to any port "${pc%%:*}" proto tcp comment "${pc##*:}" >/dev/null
    done
    sudo ufw reload >/dev/null; ok "UFW rules set for $LAN"; touch "$BASE/.ufw-done"
fi

# =============================================================================
section "Helper Scripts"
# =============================================================================
cat > "$BASE/start.sh" << STARTSH
#!/bin/bash
cd "$BASE"
docker compose pull --quiet 2>/dev/null
docker compose up -d
echo ""
echo "  Open WebUI  →  http://$LOCAL_IP:3000"
echo "  Aider UI    →  http://$LOCAL_IP:8080  (Claude Code-like editor)"
echo "  InvokeAI    →  http://$LOCAL_IP:9090  (inpainting, img2img)"
echo "  ComfyUI     →  http://$LOCAL_IP:8188  (chat-integrated image gen)"
echo "  Kiwix       →  http://$LOCAL_IP:8181  (run kiwix_download.sh first)"
echo "  Gitea       →  http://$LOCAL_IP:3001"
echo "  RAG         →  http://$LOCAL_IP:8001/health"
echo "  MCP SSE     →  http://$LOCAL_IP:8002/sse"
echo "  Portainer   →  https://$LOCAL_IP:9443"
echo ""
echo "  claude mcp add local http://$LOCAL_IP:8002/sse"
STARTSH
chmod +x "$BASE/start.sh"

cat > "$BASE/stop.sh" << STOPSH
#!/bin/bash
cd "$BASE" && docker compose down
STOPSH
chmod +x "$BASE/stop.sh"

cat > "$BASE/status.sh" << 'STATUSSH'
#!/bin/bash
echo "=== GPU ===" && nvidia-smi --query-gpu=name,memory.used,memory.total \
  --format=csv,noheader 2>/dev/null || echo "(no GPU)"
echo "" && echo "=== Containers ===" && docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "" && echo "=== Ollama ===" && docker exec ollama ollama ps 2>/dev/null || echo "(not running)"
echo "" && echo "=== RAG ===" && curl -s http://localhost:8001/health | python3 -m json.tool 2>/dev/null
STATUSSH
chmod +x "$BASE/status.sh"

cat > "$BASE/pull-models.sh" << PULLSH
#!/bin/bash
echo "Waiting for Ollama..."
until docker exec ollama ollama list &>/dev/null; do sleep 3; done

echo "Embed model (RAG — required)..."
docker exec ollama ollama pull $EMBED_MODEL

echo "Fast chat model..."
docker exec ollama ollama pull qwen2.5:7b

echo "Smart chat model..."
docker exec ollama ollama pull $CHAT_MODEL

echo "Code model..."
docker exec ollama ollama pull $CODE_MODEL

echo "Reasoning model (DeepSeek-R1 14B — optional)..."
read -rp "Pull DeepSeek-R1:14b for planning/reasoning? [y/N]: " DR
[[ "\${DR,,}" == "y" ]] && docker exec ollama ollama pull deepseek-r1:14b

echo "" && docker exec ollama ollama list
PULLSH
chmod +x "$BASE/pull-models.sh"
ok "start.sh stop.sh status.sh pull-models.sh"

cat > "$BASE/aider.sh" << AIDSH
#!/bin/bash
# Aider CLI — Claude Code-like terminal experience against any local git repo.
# Usage:
#   ./aider.sh                        # interactive, files from stdin
#   ./aider.sh src/main.py            # open specific files
#   ./aider.sh --model ollama/qwen2.5-coder:7b src/foo.py   # override model
#
# Tip: clone Gitea repos into $BASE/repos/, then:
#   cd $BASE/repos/my-project && $BASE/aider.sh <files>

MODEL="\${AIDER_MODEL:-ollama/$CODE_MODEL}"
REPO_ROOT="\$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

docker run --rm -it \\
  --network local-ai_default \\
  -v "\$REPO_ROOT:\$REPO_ROOT" \\
  -v "$BASE/repos:/repos" \\
  -w "\$REPO_ROOT" \\
  -e OLLAMA_API_BASE=http://ollama:11434 \\
  -e GIT_AUTHOR_NAME=aider \\
  -e GIT_AUTHOR_EMAIL=aider@local \\
  -e GIT_COMMITTER_NAME=aider \\
  -e GIT_COMMITTER_EMAIL=aider@local \\
  paulgauthier/aider:latest \\
  --no-auto-commits \\
  --no-check-update \\
  --model "\$MODEL" \\
  "\$@"
AIDSH
chmod +x "$BASE/aider.sh"
ok "aider.sh"

# =============================================================================
section "Systemd"
# =============================================================================
sudo tee /etc/systemd/system/local-ai.service >/dev/null << SYSD
[Unit]
Description=Local AI Stack
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$USER
WorkingDirectory=$BASE
ExecStart=/bin/bash $BASE/start.sh
ExecStop=/bin/bash $BASE/stop.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SYSD
sudo systemctl daemon-reload && sudo systemctl enable local-ai.service
ok "Systemd: local-ai.service enabled"

# =============================================================================
section "Starting Stack"
# =============================================================================
cd "$BASE"
info "Pulling images..."
docker compose pull --quiet
docker compose up -d
ok "Stack running"

if ! $IS_UPDATE && ! $NO_PULL; then
    echo ""
    read -rp "Pull Ollama models now? (~15-30 min) [Y/n]: " DO_PULL
    [[ "${DO_PULL,,}" != "n" ]] && bash "$BASE/pull-models.sh"

    # Install image generation base model (GPU-aware)
    if [[ -n "$IMG_DEFAULT" ]] && [[ -x "$SCRIPT_DIR/setup-image-models.sh" ]]; then
        echo ""
        section "Image Generation Models"
        info "GPU: ${TOTAL_VRAM}GB VRAM → $IMG_TIER"
        info "Auto-installing recommended model: $IMG_DEFAULT"
        bash "$SCRIPT_DIR/setup-image-models.sh" --auto
    fi
fi

# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Done!  GPU: ${VRAM_GB}GB → $TIER${NC}"
echo -e "${GREEN}${BOLD}  Image gen: $IMG_TIER${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Open WebUI${NC}  →  http://$LOCAL_IP:3000"
echo -e "  ${CYAN}Aider UI${NC}    →  http://$LOCAL_IP:8080  (browser coding assistant)"
echo -e "  ${CYAN}InvokeAI${NC}    →  http://$LOCAL_IP:9090  (inpainting, img2img)"
echo -e "  ${CYAN}ComfyUI${NC}     →  http://$LOCAL_IP:8188  (chat-integrated image gen)"
echo -e "  ${CYAN}Kiwix${NC}       →  http://$LOCAL_IP:8181"
echo -e "  ${CYAN}Gitea${NC}       →  http://$LOCAL_IP:3001"
echo -e "  ${CYAN}RAG${NC}         →  http://$LOCAL_IP:8001/health"
echo -e "  ${CYAN}MCP SSE${NC}     →  http://$LOCAL_IP:8002/sse"
echo -e "  ${CYAN}Portainer${NC}   →  https://$LOCAL_IP:9443"
echo ""
echo -e "  ${YELLOW}Add MCP to Claude Code:${NC}"
echo    "    claude mcp add local http://$LOCAL_IP:8002/sse"
echo ""
echo -e "  ${YELLOW}Tokens:${NC}     $BASE/.env"
echo -e "  ${YELLOW}PDFs:${NC}       $BASE/papers/"
echo -e "  ${YELLOW}Workspace:${NC}  $BASE/workspace/"
echo -e "  ${YELLOW}ZIMs:${NC}       ./kiwix_download.sh"
echo ""
echo -e "  ${YELLOW}Aider CLI:${NC}  cd your-repo && $BASE/aider.sh <files>"
echo    "  (or open browser UI above — both use your local code model)"
echo ""
echo -e "  ${YELLOW}Recommended Open WebUI Functions${NC} (install from Admin → Functions → ＋):"
echo    "    Context tracker:    https://openwebui.com/f/centrisic/context_tracker"
echo    "      → Shows tokens used vs available, progress bar, context % remaining"
echo    "    Context compaction: https://openwebui.com/f/projectmoon/checkpoint_summarization_filter"
echo    "      → Auto-summarizes old messages when context fills up (like Claude)"
echo ""
echo -e "  ${YELLOW}Save Claude usage:${NC} use local models for boilerplate, docs,"
echo    "  simple fixes. Use Claude for hard bugs,"
echo    "  multi-file refactoring, architecture decisions."
echo ""

#!/usr/bin/env python3
"""
RAG Server — code-aware chunking, multi-collection, repo ingest, webhooks.
Collections: papers (PDFs/text), code (source files, AST-split for Python)
"""
import ast, fnmatch, hashlib, json, logging, os, re, subprocess, threading, time
from pathlib import Path
from typing import Any, Optional

import chromadb
import httpx
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
              ".h",".hpp",".cs",".rb",".sh",".yaml",".yml",".toml",".sql",".md"}
SKIP_DIRS  = {"node_modules",".git","__pycache__","dist","build",".venv",
              "venv","env",".next","vendor","target","bin","obj"}
SKIP_FILES = {"package-lock.json","yarn.lock","pnpm-lock.yaml","Cargo.lock"}
MAX_BYTES  = 400_000

app = FastAPI(title="RAG Server")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# ── ChromaDB ──────────────────────────────────────────────────────────────────
def _embed_fn():
    return OllamaEmbeddingFunction(
        url=f"{OLLAMA_URL}/api/embeddings", model_name=EMBED_MODEL)

def _chroma():
    host, port = CHROMA_URL.replace("http://","").split(":")
    return chromadb.HttpClient(host=host, port=int(port))

def get_col(name: str):
    return _chroma().get_or_create_collection(name, embedding_function=_embed_fn())

# ── chunkers ─────────────────────────────────────────────────────────────────
def _doc_id(text: str, key: str) -> str:
    return hashlib.md5(f"{key}|{text[:200]}".encode()).hexdigest()

def _sliding(text: str, size=1000, overlap=150) -> list[str]:
    chunks, i = [], 0
    while i < len(text):
        chunks.append(text[i:i+size])
        i += size - overlap
    return [c for c in chunks if c.strip()]

def _chunk_python(src: str) -> list[tuple[str,str]]:
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return []
    lines = src.splitlines()
    out = []
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            chunk = "\n".join(lines[node.lineno-1:node.end_lineno])
            out.append((node.name, chunk[:4000]))
    return out

def _chunk_file(path: Path, src: str) -> list[tuple[str,str]]:
    if path.suffix == ".py":
        pairs = _chunk_python(src)
        if pairs:
            return pairs
    # function/class boundary split for JS/TS/Go/Rust etc.
    pat = re.compile(
        r'(?:^|\n)(?=(?:export\s+)?(?:async\s+)?(?:function|class|const\s+\w+\s*=\s*(?:async\s+)?\()'
        r'|^func |^type |^impl |^pub fn |^fn )',
        re.MULTILINE)
    parts = [p.strip() for p in pat.split(src) if p.strip()]
    if len(parts) > 1:
        return [(f"s{i}", p[:4000]) for i, p in enumerate(parts)]
    return [(f"c{i}", c) for i, c in enumerate(_sliding(src, 1200, 200))]

# ── ingest helpers ────────────────────────────────────────────────────────────
def ingest_file(col, fpath: Path, repo: str = ""):
    if fpath.stat().st_size > MAX_BYTES or fpath.name in SKIP_FILES:
        return
    if any(fnmatch.fnmatch(fpath.name, p) for p in ("*.min.js","*.min.css","*.map")):
        return
    try:
        src = fpath.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return
    if not src.strip():
        return
    rel = str(fpath)
    pairs = _chunk_file(fpath, src) if fpath.suffix in CODE_EXTS else \
            [(f"c{i}", c) for i, c in enumerate(_sliding(src))]
    ids, docs, metas = [], [], []
    for label, chunk in pairs:
        if not chunk.strip():
            continue
        ids.append(_doc_id(chunk, rel+label))
        docs.append(chunk)
        metas.append({"source": rel, "label": label, "repo": repo,
                       "lang": fpath.suffix.lstrip(".")})
    if ids:
        col.upsert(ids=ids, documents=docs, metadatas=metas)

def ingest_dir(col, directory: Path, repo: str = "") -> int:
    count = 0
    for f in directory.rglob("*"):
        if not f.is_file():
            continue
        if any(p in f.parts for p in SKIP_DIRS):
            continue
        ingest_file(col, f, repo)
        count += 1
    log.info("Indexed %d files from %s", count, directory)
    return count

def ingest_pdfs(col) -> int:
    try:
        import pypdf
    except ImportError:
        log.warning("pypdf not installed — skipping PDFs")
        return 0
    n = 0
    for pdf in PAPERS_DIR.glob("*.pdf"):
        try:
            text = "\n".join(p.extract_text() or ""
                             for p in pypdf.PdfReader(str(pdf)).pages)
            for i, chunk in enumerate(_sliding(text)):
                col.upsert(ids=[_doc_id(chunk, str(pdf)+str(i))],
                           documents=[chunk],
                           metadatas=[{"source": str(pdf), "label": f"p{i}",
                                       "repo": "", "lang": "pdf"}])
            n += 1
        except Exception as e:
            log.warning("PDF %s: %s", pdf.name, e)
    return n

# ── startup ───────────────────────────────────────────────────────────────────
def _startup_index():
    # wait for embed model
    for _ in range(40):
        try:
            r = httpx.get(f"{OLLAMA_URL}/api/tags", timeout=5)
            if any(EMBED_MODEL in m["name"] for m in r.json().get("models", [])):
                break
        except Exception:
            pass
        log.info("Waiting for embed model %s…", EMBED_MODEL)
        time.sleep(5)

    code_col   = get_col("code")
    papers_col = get_col("papers")
    for d in REPOS_DIR.iterdir():
        if d.is_dir():
            ingest_dir(code_col, d, d.name)
    ingest_pdfs(papers_col)
    for f in PAPERS_DIR.glob("*.txt"):
        ingest_file(papers_col, f)
    log.info("Startup index complete")

@app.on_event("startup")
async def on_startup():
    threading.Thread(target=_startup_index, daemon=True).start()

# ── endpoints ─────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    try:
        cc = _chroma()
        return {"status": "ok",
                "code":   cc.get_collection("code",   embedding_function=_embed_fn()).count(),
                "papers": cc.get_collection("papers", embedding_function=_embed_fn()).count(),
                "embed":  EMBED_MODEL, "chat": CHAT_MODEL}
    except Exception as e:
        return {"status": "error", "detail": str(e)}

class RepoRequest(BaseModel):
    url: str
    name: str = ""
    branch: str = "main"

@app.post("/ingest/repo")
async def ingest_repo(req: RepoRequest):
    name = req.name or req.url.rstrip("/").split("/")[-1].removesuffix(".git")
    dest = REPOS_DIR / name
    try:
        if dest.exists():
            subprocess.run(["git","pull"], cwd=dest, check=True, timeout=120)
        else:
            subprocess.run(["git","clone","--depth=1","-b",req.branch,
                            req.url, str(dest)], check=True, timeout=300)
    except subprocess.CalledProcessError as e:
        raise HTTPException(400, str(e))
    n = ingest_dir(get_col("code"), dest, name)
    return {"status": "ok", "repo": name, "files": n}

@app.post("/ingest/papers")
async def trigger_papers(bg: BackgroundTasks):
    bg.add_task(ingest_pdfs, get_col("papers"))
    return {"status": "queued"}

async def _webhook(payload: dict):
    repo = payload.get("repository") or {}
    url  = repo.get("clone_url") or repo.get("html_url","")
    name = repo.get("name","unknown")
    if not url:
        return {"status": "ignored"}
    dest = REPOS_DIR / name
    if dest.exists():
        subprocess.run(["git","pull"], cwd=dest, timeout=120)
    else:
        subprocess.run(["git","clone","--depth=1",url,str(dest)], timeout=300)
    n = ingest_dir(get_col("code"), dest, name)
    return {"status": "ok", "repo": name, "files": n}

@app.post("/webhook/gitea")
async def webhook_gitea(r: Request): return await _webhook(await r.json())

@app.post("/webhook/github")
async def webhook_github(r: Request): return await _webhook(await r.json())

# ── RAG chat ──────────────────────────────────────────────────────────────────
class ChatRequest(BaseModel):
    model: str = CHAT_MODEL
    messages: list[dict[str,Any]]
    stream: bool = False
    collections: list[str] = ["code","papers"]

def _context(query: str, cols: list[str]) -> str:
    parts = []
    for cname in cols:
        try:
            col = get_col(cname)
            if col.count() == 0:
                continue
            res = col.query(query_texts=[query], n_results=min(TOP_K, col.count()))
            for doc, meta in zip(res["documents"][0], res["metadatas"][0]):
                parts.append(f"### {meta.get('source','')}:{meta.get('label','')}\n"
                             f"```{meta.get('lang','')}\n{doc}\n```")
        except Exception as e:
            log.warning("col %s: %s", cname, e)
    return "\n\n".join(parts)

@app.post("/v1/chat/completions")
async def chat(req: ChatRequest):
    query   = next((m["content"] for m in reversed(req.messages)
                    if m.get("role")=="user"), "")
    context = _context(query, req.collections)
    msgs = [{"role":"system","content":
             "You are a helpful coding assistant. Use the retrieved context below.\n\n"
             f"## Context\n{context}"}] + req.messages

    payload = {"model": req.model, "messages": msgs, "stream": req.stream}

    if req.stream:
        async def gen():
            async with httpx.AsyncClient(timeout=300) as client:
                async with client.stream("POST",
                        f"{OLLAMA_URL}/v1/chat/completions", json=payload) as r:
                    async for chunk in r.aiter_bytes():
                        yield chunk
        return StreamingResponse(gen(), media_type="text/event-stream")

    async with httpx.AsyncClient(timeout=300) as client:
        r = await client.post(f"{OLLAMA_URL}/v1/chat/completions", json=payload)
    return r.json()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="0.0.0.0", port=8001, reload=False)

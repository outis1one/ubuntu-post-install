#!/usr/bin/env python3
"""
MCP Server — Claude Code-equivalent tools for Open WebUI / Claude Code CLI.
Tools: bash, file read/write/list, code search, git ops, Gitea API, repo ingest,
       offline doc search (Kiwix), web search (DuckDuckGo), Gitea↔GitHub sync.
Connects via SSE on port 8002 — add to Open WebUI Tools or ~/.claude/mcp.json
"""
import os, subprocess, textwrap
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP

WORKSPACE   = Path(os.getenv("WORKSPACE_DIR", "/workspace"))
REPOS_DIR   = Path(os.getenv("REPOS_DIR",     "/repos"))
GITEA_URL   = os.getenv("GITEA_URL",   "http://gitea:3000")
GITEA_TOKEN = os.getenv("GITEA_TOKEN", "")
GITHUB_TOKEN= os.getenv("GITHUB_TOKEN","")
RAG_URL     = os.getenv("RAG_URL",     "http://rag-server:8001")
KIWIX_URL   = os.getenv("KIWIX_URL",   "http://kiwix:80")

mcp = FastMCP("local-dev-tools")

# ── bash ──────────────────────────────────────────────────────────────────────
@mcp.tool()
def bash(command: str, cwd: str = "") -> str:
    """Run a shell command. Default cwd is /workspace."""
    work = Path(cwd) if cwd else WORKSPACE
    work.mkdir(parents=True, exist_ok=True)
    try:
        r = subprocess.run(command, shell=True, cwd=work, timeout=120,
                           capture_output=True, text=True)
        out = r.stdout + (f"\n[stderr]\n{r.stderr}" if r.stderr else "")
        if r.returncode != 0:
            out += f"\n[exit {r.returncode}]"
        return out or "(no output)"
    except subprocess.TimeoutExpired:
        return "[timeout after 120s]"
    except Exception as e:
        return f"[error] {e}"

# ── file ops ──────────────────────────────────────────────────────────────────
@mcp.tool()
def read_file(path: str) -> str:
    """Read a file. Use absolute path or relative to /workspace."""
    p = Path(path) if Path(path).is_absolute() else WORKSPACE / path
    if not p.exists():
        return f"[not found] {p}"
    if p.stat().st_size > 500_000:
        return f"[too large — {p.stat().st_size//1024}KB]"
    return p.read_text(encoding="utf-8", errors="replace")

@mcp.tool()
def write_file(path: str, content: str) -> str:
    """Write content to a file (creates parent dirs). Relative to /workspace."""
    p = Path(path) if Path(path).is_absolute() else WORKSPACE / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"Wrote {len(content)} chars to {p}"

@mcp.tool()
def list_files(path: str = "", pattern: str = "**/*") -> str:
    """List files matching a glob pattern."""
    base = Path(path) if path else WORKSPACE
    if not base.exists():
        return f"[not found] {base}"
    files = sorted(str(f.relative_to(base)) for f in base.glob(pattern) if f.is_file())
    return "\n".join(files[:500]) or "(empty)"

@mcp.tool()
def search_code(query: str, path: str = "", glob: str = "",
                case_sensitive: bool = False) -> str:
    """Search file contents with ripgrep. Returns file:line matches."""
    base = path or str(WORKSPACE)
    cmd = ["rg", "--line-number", "--no-heading"]
    if not case_sensitive:
        cmd.append("-i")
    if glob:
        cmd += ["-g", glob]
    cmd += [query, base]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        lines = r.stdout.strip().splitlines()
        if len(lines) > 200:
            lines = lines[:200] + [f"… ({len(r.stdout.splitlines())-200} more)"]
        return "\n".join(lines) or "(no matches)"
    except FileNotFoundError:
        # ripgrep not installed, fall back to grep
        r = subprocess.run(["grep", "-rn", query, base],
                           capture_output=True, text=True, timeout=30)
        return r.stdout[:8000] or "(no matches)"
    except Exception as e:
        return f"[error] {e}"

# ── git ───────────────────────────────────────────────────────────────────────
def _git(args: list[str], repo: str = "") -> str:
    cwd = Path(repo) if repo else WORKSPACE
    r = subprocess.run(["git"] + args, cwd=cwd,
                       capture_output=True, text=True, timeout=60)
    return (r.stdout + r.stderr).strip() or "(no output)"

@mcp.tool()
def git_status(repo: str = "") -> str:
    """Show git status of a repo (default: /workspace)."""
    return _git(["status", "--short"], repo)

@mcp.tool()
def git_diff(repo: str = "", cached: bool = False) -> str:
    """Show git diff (staged if cached=True)."""
    args = ["diff", "--stat", "--cached"] if cached else ["diff", "--stat"]
    return _git(args, repo) + "\n\n" + _git(
        ["diff", "--cached"] if cached else ["diff"], repo)

@mcp.tool()
def git_log(repo: str = "", n: int = 10) -> str:
    """Show last n git commits."""
    return _git(["log", f"-{n}", "--oneline", "--decorate"], repo)

@mcp.tool()
def git_commit(message: str, repo: str = "", add_all: bool = True) -> str:
    """Stage all changes and create a commit."""
    if add_all:
        _git(["add", "-A"], repo)
    return _git(["commit", "-m", message], repo)

@mcp.tool()
def git_checkout(branch: str, repo: str = "", create: bool = False) -> str:
    """Checkout a branch, optionally creating it."""
    args = ["checkout", "-b", branch] if create else ["checkout", branch]
    return _git(args, repo)

# ── Search: unified (Kiwix offline + DuckDuckGo live) ───────────────────────
# Kiwix ZIMs have complete, high-quality articles but may be months old.
# DDG has live results but lower signal-to-noise. The unified search tool
# checks both and lets the model see freshness info to judge which to trust.
#
# Heuristic: topics that change fast (releases, CVEs, "latest X") get flagged
# as potentially stale in offline results. Timeless topics (algorithms, language
# docs, math) are fine from Kiwix and skip the web hit entirely.

import re as _re
from datetime import datetime as _dt

# Words that suggest the query needs fresh data
_FRESH_KEYWORDS = _re.compile(
    r'\b(latest|newest|recent|2025|2026|update|release|version|changelog|CVE|vulnerability|'
    r'breaking change|deprecat|current|today|this year|this month|announce|just released)\b',
    _re.IGNORECASE
)

def _kiwix_search(query: str, limit: int = 5) -> list[dict]:
    """Search Kiwix, return list of {title, snippet, path, source}."""
    try:
        r = httpx.get(f"{KIWIX_URL}/search",
                      params={"pattern": query, "pageLength": limit},
                      timeout=15, follow_redirects=True)
        if r.status_code != 200:
            return []
        html = r.text
        results = []
        # Try structured parse first
        articles = _re.findall(
            r'<a[^>]+href="(/[^"]+)"[^>]*>\s*<span[^>]*>([^<]*)</span>.*?'
            r'(?:<cite[^>]*>([^<]*)</cite>)?.*?'
            r'(?:<p[^>]*>(.*?)</p>)?',
            html, _re.DOTALL
        )
        if articles:
            for path, title, cite, snippet in articles[:limit]:
                snippet_clean = _re.sub(r'<[^>]+>', '', snippet or '').strip()[:300]
                results.append({"title": title.strip(), "snippet": snippet_clean,
                                "path": path, "source": cite.strip() if cite else "kiwix"})
        else:
            # Fallback: grab any links
            for path, title in _re.findall(r'<a[^>]+href="(/[^"]+)"[^>]*>([^<]+)</a>', html)[:limit]:
                results.append({"title": title.strip(), "snippet": "",
                                "path": path, "source": "kiwix"})
        return results
    except Exception:
        return []

def _ddg_search(query: str, limit: int = 5) -> list[dict]:
    """Search DuckDuckGo, return list of {title, snippet, url}."""
    try:
        from duckduckgo_search import DDGS
        results = []
        with DDGS() as ddgs:
            for r in ddgs.text(query, max_results=limit):
                results.append({"title": r["title"], "snippet": r["body"], "url": r["href"]})
        return results
    except Exception:
        return []

@mcp.tool()
def search(query: str, limit: int = 5) -> str:
    """Unified search: checks offline docs (Kiwix) AND live web (DuckDuckGo).
    Returns results from both with freshness guidance.
    For timeless topics (algorithms, docs): offline results are sufficient.
    For time-sensitive topics (releases, CVEs): live results are flagged as preferred."""
    needs_fresh = bool(_FRESH_KEYWORDS.search(query))
    output_parts = []

    # Always search Kiwix (fast, local)
    kiwix_results = _kiwix_search(query, limit)
    if kiwix_results:
        header = "## Offline Docs (Kiwix)"
        if needs_fresh:
            header += "  ⚠️ POSSIBLY STALE — query looks time-sensitive, prefer live results below"
        output_parts.append(header)
        for i, r in enumerate(kiwix_results, 1):
            entry = f"{i}. **{r['title']}**"
            if r["source"] and r["source"] != "kiwix":
                entry += f" ({r['source']})"
            if r["snippet"]:
                entry += f"\n   {r['snippet']}"
            entry += f"\n   → read_doc('{r['path']}')"
            output_parts.append(entry)

    # Search DDG if: query needs fresh data, OR Kiwix returned nothing, OR always (to compare)
    do_web = needs_fresh or not kiwix_results
    ddg_results = []
    if do_web:
        ddg_results = _ddg_search(query, limit)

    if ddg_results:
        header = "## Live Web (DuckDuckGo)"
        if needs_fresh:
            header += "  ✓ PREFER THESE for this query"
        output_parts.append(header)
        for i, r in enumerate(ddg_results, 1):
            output_parts.append(f"{i}. **{r['title']}**\n   {r['snippet']}\n   {r['url']}")
    elif do_web:
        output_parts.append("## Live Web (DuckDuckGo)\n(no results or DDG unreachable)")

    if not kiwix_results and not ddg_results:
        return f"No results for '{query}' from either offline docs or web search."

    # Freshness note
    if kiwix_results and not needs_fresh and not ddg_results:
        output_parts.append("\n_Offline results look sufficient for this topic. "
                            "Use web_search() if you need to verify currency._")

    return "\n\n".join(output_parts)

@mcp.tool()
def read_doc(path: str) -> str:
    """Read a full article from Kiwix by its path (from search results).
    Example: read_doc('/wikipedia_en_all/A/Python_(programming_language)')"""
    try:
        r = httpx.get(f"{KIWIX_URL}{path}", timeout=15, follow_redirects=True)
        if r.status_code != 200:
            return f"Not found: {path} (HTTP {r.status_code})"
        # Strip HTML tags, keep text content
        text = _re.sub(r'<script[^>]*>.*?</script>', '', r.text, flags=_re.DOTALL)
        text = _re.sub(r'<style[^>]*>.*?</style>', '', text, flags=_re.DOTALL)
        text = _re.sub(r'<[^>]+>', ' ', text)
        text = _re.sub(r'\s+', ' ', text).strip()
        if len(text) > 8000:
            text = text[:8000] + "\n\n[... truncated — article continues ...]"
        return text
    except Exception as e:
        return f"Error reading doc: {e}"

@mcp.tool()
def web_search(query: str, num_results: int = 5) -> str:
    """Search ONLY the live web via DuckDuckGo. Use search() instead for most queries —
    it checks both offline and live. Use this directly only when you specifically need
    live-only results (e.g., verifying if offline info is current)."""
    results = _ddg_search(query, num_results)
    if not results:
        return f"No web results for '{query}'"
    return "\n\n".join(f"**{r['title']}**\n  {r['snippet']}\n  {r['url']}" for r in results)

# ── Gitea API ─────────────────────────────────────────────────────────────────
def _gitea(method: str, path: str, body: dict = {}) -> dict:
    if not GITEA_TOKEN:
        return {"error": "GITEA_TOKEN not set in .env"}
    url = f"{GITEA_URL}/api/v1{path}"
    headers = {"Authorization": f"token {GITEA_TOKEN}",
               "Content-Type": "application/json"}
    r = httpx.request(method, url, json=body or None, headers=headers, timeout=30)
    try:
        return r.json()
    except Exception:
        return {"status": r.status_code, "text": r.text}

@mcp.tool()
def gitea_list_repos() -> str:
    """List your Gitea repos."""
    repos = _gitea("GET", "/repos/search?limit=50")
    if "error" in repos:
        return repos["error"]
    return "\n".join(f"{r['full_name']} — {r.get('description','')}"
                     for r in repos.get("data", []))

@mcp.tool()
def gitea_create_repo(name: str, private: bool = True, description: str = "") -> str:
    """Create a new Gitea repository."""
    r = _gitea("POST", "/user/repos",
               {"name": name, "private": private, "description": description,
                "auto_init": True, "default_branch": "main"})
    return r.get("html_url") or str(r)

@mcp.tool()
def gitea_create_issue(repo: str, title: str, body: str = "") -> str:
    """Create an issue on a Gitea repo (format: owner/repo)."""
    r = _gitea("POST", f"/repos/{repo}/issues", {"title": title, "body": body})
    return r.get("html_url") or str(r)

# ── GitHub API ────────────────────────────────────────────────────────────────
@mcp.tool()
def github_api(method: str, endpoint: str, body: str = "") -> str:
    """Call the GitHub REST API. endpoint e.g. /repos/owner/repo/issues"""
    if not GITHUB_TOKEN:
        return "GITHUB_TOKEN not set in .env"
    import json as _json
    headers = {"Authorization": f"Bearer {GITHUB_TOKEN}",
               "Accept": "application/vnd.github+json"}
    r = httpx.request(method.upper(), f"https://api.github.com{endpoint}",
                      json=_json.loads(body) if body else None,
                      headers=headers, timeout=30)
    try:
        return _json.dumps(r.json(), indent=2)
    except Exception:
        return r.text

# ── Gitea ↔ GitHub sync ──────────────────────────────────────────────────────
@mcp.tool()
def gitea_github_sync(mode: str = "all", repo: str = "") -> str:
    """Run Gitea↔GitHub mirror sync. mode: all|pull|push|list. repo: optional owner/name."""
    cmd = ["/app/gitea-github-sync.sh"]
    if mode == "pull":   cmd.append("--pull-only")
    elif mode == "push": cmd.append("--push-only")
    elif mode == "list": cmd.append("--list")
    if repo:
        cmd.extend(["--repo", repo])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600,
                           env={**os.environ, "SYNC_ENV": "/app/.env"})
        return (r.stdout + r.stderr).strip() or "Sync completed (no output)"
    except subprocess.TimeoutExpired:
        return "Sync timed out after 10 minutes"
    except Exception as e:
        return f"Sync failed: {e}"

# ── RAG ingest ────────────────────────────────────────────────────────────────
@mcp.tool()
def ingest_repo(url: str, name: str = "", branch: str = "main") -> str:
    """Clone a git repo and index it in the RAG code collection."""
    r = httpx.post(f"{RAG_URL}/ingest/repo",
                   json={"url": url, "name": name, "branch": branch}, timeout=300)
    return r.text

@mcp.tool()
def rag_health() -> str:
    """Check RAG server status and indexed document counts."""
    try:
        r = httpx.get(f"{RAG_URL}/health", timeout=10)
        return r.text
    except Exception as e:
        return f"RAG server unreachable: {e}"

if __name__ == "__main__":
    import uvicorn
    app = mcp.sse_app()
    uvicorn.run(app, host="0.0.0.0", port=8002)

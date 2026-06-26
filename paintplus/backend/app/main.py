from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, HTMLResponse
from contextlib import asynccontextmanager
from pathlib import Path
import asyncio
import os

from app.config import settings
from app.database import init_db
from app.routers import projects, edits, images, patches, generate, tools, ai_tools, print_tools
from app.routers import gpu_status


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize database on startup; auto-install Real-ESRGAN NCNN in background."""
    init_db()
    # Kick off NCNN install in background if no AI upscaler detected
    from app.services.upscale import probe_upscale_capabilities, ensure_ncnn_installed
    caps = probe_upscale_capabilities()
    if not caps["realesrgan_pytorch"] and not caps["realesrgan_ncnn"]:
        asyncio.create_task(ensure_ncnn_installed())
    # Pre-download SAM model in background so first click is fast
    from app.services.sam_service import ensure_sam_installed
    asyncio.create_task(ensure_sam_installed())

    # If local GPU provider is active, log GPU info at startup
    if settings.ai_provider.lower() == "local_gpu" or any(
        v.lower() == "local_gpu"
        for v in [
            settings.ai_provider_inpaint,
            settings.ai_provider_txt2img,
            settings.ai_provider_img2img,
            settings.ai_provider_outpaint,
        ]
        if v
    ):
        from app.services.gpu_detect import get_cached_gpu_info
        info = get_cached_gpu_info()
        cc_str = f" | CC={info.compute_capability}" if info.compute_capability else ""
        print(
            f"[gpu] {info.device_name} | {info.vram_total_gb:.1f} GB{cc_str} | "
            f"tier={info.tier} | fp16={info.fp16}"
        )
        for w in info.warnings:
            print(f"[gpu] ⚠ {w}")
        if settings.auto_download_models:
            # Download model weight files to disk cache in background so first
            # user request loads from local disk instead of the internet.
            from app.services.local_diffusion import prefetch_model_files
            asyncio.create_task(prefetch_model_files())

    yield


app = FastAPI(
    title="AI Photo Edit API",
    description="API for AI-powered photo editing with mask-scoped regeneration",
    version="1.0.0",
    lifespan=lifespan
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(projects.router)
app.include_router(edits.router)
app.include_router(images.router)
app.include_router(patches.router)
app.include_router(generate.router)
app.include_router(tools.router)
app.include_router(ai_tools.router)
app.include_router(print_tools.router)
app.include_router(gpu_status.router)


@app.get("/api")
def api_root():
    """API info endpoint"""
    return {
        "name": "AI Photo Edit API",
        "version": "1.0.0",
        "status": "running"
    }


@app.get("/health")
def health():
    """Health check endpoint"""
    return {"status": "healthy"}


# Static files directory
STATIC_DIR = Path("/app/static")


class NoCacheStaticFiles(StaticFiles):
    """webpack outputs a fixed 'bundle.js' filename (no content hash), so
    browsers can keep serving a stale cached copy after a rebuild unless
    forced to revalidate on every request."""

    def file_response(self, *args, **kwargs):
        response = super().file_response(*args, **kwargs)
        response.headers["Cache-Control"] = "no-cache"
        return response


# Serve static assets - mount subdirectories if they exist
if STATIC_DIR.exists():
    # React-style assets folder
    if (STATIC_DIR / "assets").exists():
        app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")
    # miniPaint dist folder (webpack bundle) - no-cache so code updates are picked up immediately
    if (STATIC_DIR / "dist").exists():
        app.mount("/dist", NoCacheStaticFiles(directory=STATIC_DIR / "dist"), name="dist")
    # miniPaint images folder
    if (STATIC_DIR / "images").exists():
        app.mount("/images", StaticFiles(directory=STATIC_DIR / "images"), name="images")
    # miniPaint CSS folder - no-cache, same reasoning as /dist
    if (STATIC_DIR / "src").exists():
        app.mount("/src", NoCacheStaticFiles(directory=STATIC_DIR / "src"), name="src")


@app.get("/", response_class=HTMLResponse)
async def serve_spa():
    """Serve miniPaint index.html"""
    index_path = STATIC_DIR / "index.html"
    if index_path.exists():
        return FileResponse(index_path, headers={"Cache-Control": "no-cache"})
    return HTMLResponse("<h1>Frontend not built. Run npm build in frontend/</h1>")


@app.get("/{full_path:path}")
async def serve_spa_routes(request: Request, full_path: str):
    """
    Catch-all route for serving static files.
    Serves static files if they exist, otherwise returns index.html.
    """
    # Don't catch API routes
    if full_path.startswith(("projects", "edits", "patches", "tools", "generate", "health", "docs", "openapi.json", "api")):
        return {"detail": "Not Found"}

    # Check if it's a static file
    static_file = STATIC_DIR / full_path
    if static_file.exists() and static_file.is_file():
        return FileResponse(static_file)

    # Otherwise serve index.html
    index_path = STATIC_DIR / "index.html"
    if index_path.exists():
        return FileResponse(index_path, headers={"Cache-Control": "no-cache"})

    return HTMLResponse("<h1>Frontend not built</h1>", status_code=404)

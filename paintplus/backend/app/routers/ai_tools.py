"""
AI tools router — LaMa inpaint, background removal, remote generation, config.
All endpoints are under /api prefix.
"""

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from typing import Optional
import base64
import asyncio
import json
from io import BytesIO

from app.services.local_inpaint import (
    lama_inpaint, opencv_inpaint, lama_available, gpu_available, rembg_available,
)

router = APIRouter(prefix="/api", tags=["ai-tools"])


# ─── Request / response models ───────────────────────────────────────────────

class EraseRequest(BaseModel):
    image: str  # base64
    mask: str   # base64


class InpaintRemoteRequest(BaseModel):
    image: str
    mask: str
    prompt: str
    negative_prompt: Optional[str] = ""
    steps: Optional[int] = 30
    cfg_scale: Optional[float] = 7.5
    model: Optional[str] = None


class Txt2ImgRequest(BaseModel):
    prompt: str
    width: Optional[int] = 1024
    height: Optional[int] = 1024
    negative_prompt: Optional[str] = ""
    steps: Optional[int] = 30
    cfg_scale: Optional[float] = 7.5
    model: Optional[str] = None
    seed: Optional[int] = 0


class Img2ImgRequest(BaseModel):
    image: str
    prompt: str
    strength: Optional[float] = 0.75
    negative_prompt: Optional[str] = ""
    steps: Optional[int] = 30
    cfg_scale: Optional[float] = 7.5
    model: Optional[str] = None


class OutpaintRequest(BaseModel):
    image: str
    direction: str  # left | right | top | bottom
    size: Optional[int] = 256
    prompt: Optional[str] = ""


class BgRemoveRequest(BaseModel):
    image: str


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _decode(b64: str) -> bytes:
    return base64.b64decode(b64)


def _encode(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _require_remote(operation: str = None):
    from app.services.remote_provider import get_remote_provider
    from app.config import settings
    provider = get_remote_provider(operation)
    if provider is None:
        if (settings.ai_provider or "").lower() == "local_gpu":
            raise HTTPException(
                status_code=503,
                detail=(
                    "local_gpu provider failed to load — diffusers may be incompatible with "
                    "the installed PyTorch version. Check container logs for details. "
                    "If you see 'torch has no attribute xpu', rebuild the container from the "
                    "correct branch so the pinned diffusers<0.29.0 is installed."
                )
            )
        op_hint = f"AI_PROVIDER_{operation.upper()} or " if operation else ""
        raise HTTPException(
            status_code=503,
            detail=f"No remote AI provider configured for '{operation or 'default'}'. "
                   f"Set {op_hint}AI_PROVIDER in .env (openai / invokeai / comfyui)."
        )
    return provider


# ─── Local inpaint endpoints ─────────────────────────────────────────────────

@router.post("/erase")
async def erase(req: EraseRequest):
    """
    Magic eraser: remove object / fill region using LaMa (local, no API key needed).
    Falls back to OpenCV if LaMa not installed.
    """
    try:
        image_bytes = _decode(req.image)
        mask_bytes = _decode(req.mask)

        if lama_available():
            result = await asyncio.get_event_loop().run_in_executor(
                None, lama_inpaint, image_bytes, mask_bytes
            )
            method = "lama"
        else:
            result = await asyncio.get_event_loop().run_in_executor(
                None, opencv_inpaint, image_bytes, mask_bytes
            )
            method = "opencv"

        return {"result": _encode(result), "method": method}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/inpaint/lama")
async def inpaint_lama(req: EraseRequest):
    """LaMa structural inpainting."""
    if not lama_available():
        raise HTTPException(status_code=503, detail="simple-lama-inpainting not installed.")
    try:
        result = await asyncio.get_event_loop().run_in_executor(
            None, lama_inpaint, _decode(req.image), _decode(req.mask)
        )
        return {"result": _encode(result)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/inpaint/fast")
async def inpaint_fast(req: EraseRequest):
    """OpenCV fast inpainting (CPU, milliseconds)."""
    try:
        result = await asyncio.get_event_loop().run_in_executor(
            None, opencv_inpaint, _decode(req.image), _decode(req.mask)
        )
        return {"result": _encode(result)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/background/remove")
async def background_remove(req: BgRemoveRequest):
    """Remove background — rembg if available, else U2Net."""
    try:
        image_bytes = _decode(req.image)

        # Try rembg first
        if rembg_available():
            from app.services.local_inpaint import remove_background_rembg
            result = await asyncio.get_event_loop().run_in_executor(
                None, remove_background_rembg, image_bytes
            )
            return {"result": _encode(result), "method": "rembg"}

        # Fall back to U2Net (existing implementation)
        from PIL import Image
        from io import BytesIO as _BytesIO
        img = Image.open(_BytesIO(image_bytes)).convert("RGB")
        from app.routers.tools import _remove_background_u2net
        result = await _remove_background_u2net(img)
        return {"result": _encode(result), "method": "u2net"}

    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


# ─── Remote provider endpoints ───────────────────────────────────────────────

@router.post("/inpaint/remote")
async def inpaint_remote(req: InpaintRemoteRequest):
    """Inpaint via configured remote provider (InvokeAI / ComfyUI / OpenAI)."""
    provider = _require_remote("inpaint")
    try:
        params = {
            "negative_prompt": req.negative_prompt or "",
            "steps": req.steps,
            "cfg_scale": req.cfg_scale,
        }
        if req.model:
            params["model"] = req.model
        result = await provider.inpaint(_decode(req.image), _decode(req.mask), req.prompt, params)
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/generate/progress")
async def generation_progress_stream():
    """
    SSE stream of local GPU pipeline inference progress.
    Events are JSON arrays of pipeline state objects, emitted every 200 ms.
    Each object: {pipeline, state, step, total_steps, progress, message, model_id, …}
    Clients open this with EventSource before firing a generation POST,
    then close it when the POST resolves.
    """
    from app.services.local_diffusion import get_all_model_states

    async def event_gen():
        try:
            while True:
                states = get_all_model_states()
                yield f"data: {json.dumps(states)}\n\n"
                await asyncio.sleep(0.2)
        except asyncio.CancelledError:
            pass

    return StreamingResponse(
        event_gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


@router.post("/generate/txt2img")
async def txt2img(req: Txt2ImgRequest):
    """Text-to-image via configured remote provider."""
    provider = _require_remote("txt2img")
    try:
        params = {
            "negative_prompt": req.negative_prompt or "",
            "steps": req.steps,
            "cfg_scale": req.cfg_scale,
            "seed": req.seed or 0,
        }
        if req.model:
            params["model"] = req.model
        result = await provider.txt2img(req.prompt, req.width, req.height, params)
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/generate/img2img")
async def img2img(req: Img2ImgRequest):
    """Image-to-image via configured remote provider."""
    provider = _require_remote("img2img")
    try:
        params = {
            "negative_prompt": req.negative_prompt or "",
            "steps": req.steps,
            "cfg_scale": req.cfg_scale,
        }
        if req.model:
            params["model"] = req.model
        result = await provider.img2img(_decode(req.image), req.prompt, req.strength, params)
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/generate/outpaint")
async def outpaint(req: OutpaintRequest):
    """Expand canvas in given direction via remote provider."""
    provider = _require_remote("outpaint")
    if req.direction not in ("left", "right", "top", "bottom"):
        raise HTTPException(status_code=400, detail="direction must be left/right/top/bottom")
    try:
        result = await provider.outpaint(_decode(req.image), req.direction, req.size, req.prompt or "")
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


# ─── Config / capabilities ────────────────────────────────────────────────────

class ConfigUpdateRequest(BaseModel):
    ai_provider: Optional[str] = None
    # Per-operation overrides (blank = use default)
    ai_provider_inpaint: Optional[str] = None
    ai_provider_txt2img: Optional[str] = None
    ai_provider_img2img: Optional[str] = None
    ai_provider_outpaint: Optional[str] = None
    # Credentials / URLs
    openai_api_key: Optional[str] = None
    openai_model: Optional[str] = None
    invokeai_url: Optional[str] = None
    invokeai_default_model: Optional[str] = None
    comfyui_url: Optional[str] = None
    comfyui_default_model: Optional[str] = None
    replicate_api_key: Optional[str] = None
    stability_api_key: Optional[str] = None


@router.post("/config")
async def update_config(req: ConfigUpdateRequest):
    """
    Apply runtime provider settings (no restart needed).
    Values are applied to the live settings object in-process.
    They do NOT persist across restarts — set them in .env for permanence.
    """
    from app.config import settings

    _str_fields = [
        "ai_provider", "ai_provider_inpaint", "ai_provider_txt2img",
        "ai_provider_img2img", "ai_provider_outpaint",
        "openai_api_key", "openai_model",
        "invokeai_url", "invokeai_default_model",
        "comfyui_url", "comfyui_default_model",
        "replicate_api_key", "stability_api_key",
    ]
    for field in _str_fields:
        val = getattr(req, field, None)
        if val is not None:
            setattr(settings, field, val)

    return {
        "status": "ok",
        "ai_provider": settings.ai_provider,
        "overrides": {
            "inpaint":  settings.ai_provider_inpaint  or None,
            "txt2img":  settings.ai_provider_txt2img  or None,
            "img2img":  settings.ai_provider_img2img  or None,
            "outpaint": settings.ai_provider_outpaint or None,
        }
    }


async def _check_provider(operation: str) -> dict:
    """Health-check the provider for a specific operation."""
    from app.services.remote_provider import get_remote_provider
    try:
        p = get_remote_provider(operation)
        if p is None:
            return {"provider": None, "healthy": False}
        healthy = await asyncio.wait_for(p.health(), timeout=5.0)
        return {"provider": p.__class__.__name__.replace("Provider", "").lower(), "healthy": healthy}
    except Exception:
        return {"provider": None, "healthy": False}


@router.get("/config")
async def get_config():
    """
    Return capability flags so the frontend can show/hide tools.
    Includes per-operation provider assignments and health status.
    """
    from app.config import settings

    # Run health checks for each operation concurrently
    ops = ["inpaint", "txt2img", "img2img", "outpaint"]
    results = await asyncio.gather(*[_check_provider(op) for op in ops])
    op_status = dict(zip(ops, results))

    # Default provider for display (used when no per-op override)
    default_name = (settings.ai_provider or "").lower() or None

    from app.services.gpu_detect import get_cached_gpu_info
    gpu_info = get_cached_gpu_info()

    return {
        "local": {
            "lama": lama_available(),
            "rembg": rembg_available(),
            "opencv": True,
            "gpu_detected":    gpu_available(),
            "gpu_backend":     gpu_info.backend,
            "gpu_device":      gpu_info.device_name,
            "gpu_vram_total":  gpu_info.vram_total_gb,
            "gpu_vram_free":   gpu_info.vram_free_gb,
            "gpu_cc":          gpu_info.compute_capability,
            "gpu_fp16":        gpu_info.fp16,
            "gpu_bf16":        gpu_info.bf16,
            "gpu_fp8":         gpu_info.fp8,
            "gpu_tensor_cores": gpu_info.tensor_cores,
            "gpu_tier":        gpu_info.tier,
            "gpu_eff_vram":    gpu_info.effective_vram_gb,
            "local_gpu_available": gpu_info.backend in ("cuda", "mps"),
            "local_gpu_capabilities": gpu_info.capabilities,
            "local_gpu_warnings": gpu_info.warnings,
        },
        "remote": {
            "default_provider": default_name,
            # Legacy field kept for backwards compat with badge/capabilities checks
            "provider": default_name,
            "healthy": any(v["healthy"] for v in op_status.values()),
            "operations": op_status,
            "overrides": {
                "inpaint":  settings.ai_provider_inpaint  or None,
                "txt2img":  settings.ai_provider_txt2img  or None,
                "img2img":  settings.ai_provider_img2img  or None,
                "outpaint": settings.ai_provider_outpaint or None,
            },
        }
    }


# ─── Selection image operations ─────────────────────────────────────────────

class ScaleSelectionRequest(BaseModel):
    image: str           # base64 full canvas
    mask: str            # base64 selection mask (white = object)
    scale_pct: float = 103.0  # 103 = 3% bigger, 95 = 5% smaller


class AiEditRegionRequest(BaseModel):
    image: str
    mask: str
    instruction: str
    negative_prompt: str = ""
    steps: int = 30
    cfg_scale: float = 7.5


class PasteIntoSelectionRequest(BaseModel):
    image: str        # base64 target canvas
    mask: str         # base64 selection mask
    paste_image: str  # base64 image to paste


@router.post("/image/scale-selection")
async def scale_selection(req: ScaleSelectionRequest):
    """
    Scale the object selected by mask by scale_pct%, AI-fill the exposed gap.
    Works purely with local tools (LaMa/OpenCV) — no remote provider needed.
    """
    try:
        import numpy as np
        from PIL import Image, ImageFilter
    except ImportError:
        raise HTTPException(status_code=500, detail="PIL/numpy not available")

    img  = Image.open(BytesIO(_decode(req.image))).convert("RGB")
    mask = Image.open(BytesIO(_decode(req.mask))).convert("L")
    if img.size != mask.size:
        mask = mask.resize(img.size, Image.LANCZOS)

    mask_arr = np.array(mask)
    ys, xs = np.where(mask_arr > 128)
    if len(xs) == 0:
        raise HTTPException(status_code=400, detail="Empty mask — nothing to scale")

    minx, maxx = int(xs.min()), int(xs.max())
    miny, maxy = int(ys.min()), int(ys.max())
    cx, cy = (minx + maxx) / 2.0, (miny + maxy) / 2.0
    obj_w, obj_h = maxx - minx + 1, maxy - miny + 1

    scale  = req.scale_pct / 100.0
    new_w  = max(1, round(obj_w * scale))
    new_h  = max(1, round(obj_h * scale))

    # Extract masked object crop (RGBA with mask as alpha)
    img_rgba  = img.convert("RGBA")
    obj_crop  = img_rgba.crop((minx, miny, maxx + 1, maxy + 1))
    mask_crop = mask.crop((minx, miny, maxx + 1, maxy + 1))
    r, g, b, _ = obj_crop.split()
    obj_masked = Image.merge("RGBA", (r, g, b, mask_crop))
    scaled_obj = obj_masked.resize((new_w, new_h), Image.LANCZOS)

    # AI-fill the original mask area (gap) with LaMa/OpenCV
    gap_mask  = mask.filter(ImageFilter.MaxFilter(9))   # expand ~4px for clean seam
    gap_bytes = BytesIO()
    img.save(gap_bytes, format="PNG")
    gap_mask_bytes = BytesIO()
    gap_mask.save(gap_mask_bytes, format="PNG")

    try:
        if lama_available():
            filled_bytes = await asyncio.get_event_loop().run_in_executor(
                None, lama_inpaint, gap_bytes.getvalue(), gap_mask_bytes.getvalue()
            )
        else:
            filled_bytes = await asyncio.get_event_loop().run_in_executor(
                None, opencv_inpaint, gap_bytes.getvalue(), gap_mask_bytes.getvalue()
            )
        filled = Image.open(BytesIO(filled_bytes)).convert("RGBA")
    except Exception as exc:
        print(f"[scale-selection] fill fallback: {exc}")
        filled = img.convert("RGBA")

    # Paste scaled object centered on original centroid
    px = round(cx - new_w / 2)
    py = round(cy - new_h / 2)
    result = filled.copy()
    result.paste(scaled_obj, (px, py), scaled_obj.split()[3])

    out = BytesIO()
    result.convert("RGB").save(out, format="PNG")
    return {"result": _encode(out.getvalue())}


@router.post("/image/ai-edit-region")
async def ai_edit_region(req: AiEditRegionRequest):
    """
    AI-edit the selected region using the configured inpaint provider.
    Works with local_gpu, InvokeAI, ComfyUI, or OpenAI.
    """
    provider = _require_remote("inpaint")
    try:
        result_bytes = await provider.inpaint(
            _decode(req.image),
            _decode(req.mask),
            req.instruction,
            {"negative_prompt": req.negative_prompt, "steps": req.steps, "cfg_scale": req.cfg_scale},
        )
    except Exception as exc:
        import traceback; traceback.print_exc()
        msg = str(exc)
        if "Errno -3" in msg or "Name or service not known" in msg or "ConnectError" in msg:
            raise HTTPException(
                status_code=503,
                detail=(
                    "AI model files not yet downloaded — container DNS appears to be blocked. "
                    "Fix: sudo iptables -I DOCKER-USER -p udp --dport 53 -j ACCEPT on the host, "
                    "or pre-download the model: pip install huggingface-hub && "
                    "huggingface-cli download diffusers/stable-diffusion-xl-1.0-inpainting-0.1 "
                    "--cache-dir ./data/hf_cache"
                )
            )
        raise HTTPException(status_code=500, detail=msg)
    return {"result": _encode(result_bytes)}


@router.post("/image/paste-into-selection")
async def paste_into_selection(req: PasteIntoSelectionRequest):
    """
    Scale a clipboard image to the selection bounding box, mask it to the
    selection shape, and composite it over the original canvas.
    """
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        raise HTTPException(status_code=500, detail="PIL/numpy not available")

    img       = Image.open(BytesIO(_decode(req.image))).convert("RGBA")
    mask      = Image.open(BytesIO(_decode(req.mask))).convert("L")
    paste_img = Image.open(BytesIO(_decode(req.paste_image))).convert("RGBA")

    if img.size != mask.size:
        mask = mask.resize(img.size, Image.LANCZOS)

    mask_arr = np.array(mask)
    ys, xs   = np.where(mask_arr > 128)
    if len(xs) == 0:
        raise HTTPException(status_code=400, detail="Empty mask")

    minx, maxx = int(xs.min()), int(xs.max())
    miny, maxy = int(ys.min()), int(ys.max())
    target_w   = maxx - minx + 1
    target_h   = maxy - miny + 1

    # Scale clipboard image to fit the selection bounding box
    paste_scaled = paste_img.resize((target_w, target_h), Image.LANCZOS)

    # Clip paste to selection shape using mask
    mask_crop = mask.crop((minx, miny, maxx + 1, maxy + 1))
    r, g, b, a = paste_scaled.split()
    mask_np = np.array(mask_crop)
    alpha_np = np.array(a)
    combined = (alpha_np.astype(np.uint16) * mask_np.astype(np.uint16) // 255).astype(np.uint8)
    paste_final = Image.merge("RGBA", (r, g, b, Image.fromarray(combined)))

    result = img.copy()
    result.paste(paste_final, (minx, miny), paste_final.split()[3])

    out = BytesIO()
    result.convert("RGB").save(out, format="PNG")
    return {"result": _encode(out.getvalue())}


# ─── SAM (Segment Anything) ──────────────────────────────────────────────────

class SegmentPointRequest(BaseModel):
    image: str                          # base64 PNG/JPEG
    points: list[list[int]]             # [[x, y], ...]  original image coords
    labels: list[int]                   # 1=include, 0=exclude — same length as points


@router.post("/segment/point")
async def segment_point(req: SegmentPointRequest):
    """
    Run SAM point-prompt segmentation.
    Returns a binary mask PNG (white = selected area).
    Auto-downloads the SAM ViT-B model (~375 MB) on first call.
    """
    if not req.points:
        raise HTTPException(status_code=400, detail="At least one point required.")
    if len(req.points) != len(req.labels):
        raise HTTPException(status_code=400, detail="points and labels must have the same length.")

    try:
        image_bytes = base64.b64decode(req.image)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Could not decode image: {e}")

    from app.services.sam_service import predict_points, get_install_status
    try:
        mask_bytes = await predict_points(
            image_bytes,
            [tuple(p) for p in req.points],
            req.labels,
        )
        return {
            "mask": base64.b64encode(mask_bytes).decode(),
            "sam_install": get_install_status(),
        }
    except RuntimeError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/segment/install-status")
def segment_install_status():
    """Poll SAM model download progress."""
    from app.services.sam_service import get_install_status, sam_model_available
    status = get_install_status()
    status["model_ready"] = sam_model_available()
    return status


@router.post("/segment/install")
async def segment_install():
    """Trigger SAM model download explicitly (also auto-triggered on first /segment/point call)."""
    from app.services.sam_service import ensure_sam_installed, get_install_status
    asyncio.create_task(ensure_sam_installed())
    return get_install_status()


# ─── Enhance ─────────────────────────────────────────────────────────────────

import io as _io
import numpy as _np
import cv2 as _cv2
from PIL import Image as _Image

class EnhanceRequest(BaseModel):
    image: str          # base64
    strength: float = 1.0


def _enhance_image(image_bytes: bytes, strength: float) -> bytes:
    """
    Apply a chain of non-AI image enhancements, each blended with `strength` (0–1).

    Steps:
      1. Auto white balance (gray-world)
      2. CLAHE on L channel of LAB colorspace
      3. Auto saturation boost in HSV (×1.15, clamped)
      4. Mild unsharp mask (gaussian sigma=1.0, delta weight=0.3)
    """
    strength = max(0.0, min(1.0, float(strength)))

    # Decode to RGB numpy array
    pil = _Image.open(_io.BytesIO(image_bytes)).convert("RGB")
    orig = _np.array(pil, dtype=_np.float32)  # H×W×3, float [0,255]

    img = orig.copy()

    # ── Step 1: Auto white balance (gray-world) ──────────────────────────────
    mean_r = img[:, :, 0].mean()
    mean_g = img[:, :, 1].mean()
    mean_b = img[:, :, 2].mean()
    overall_mean = (mean_r + mean_g + mean_b) / 3.0

    def _scale(channel, channel_mean):
        if channel_mean == 0:
            return channel
        return channel * (overall_mean / channel_mean)

    wb = img.copy()
    wb[:, :, 0] = _np.clip(_scale(img[:, :, 0], mean_r), 0, 255)
    wb[:, :, 1] = _np.clip(_scale(img[:, :, 1], mean_g), 0, 255)
    wb[:, :, 2] = _np.clip(_scale(img[:, :, 2], mean_b), 0, 255)

    img = (orig + strength * (wb - orig)).clip(0, 255)

    # ── Step 2: CLAHE on L channel (LAB) ────────────────────────────────────
    img_u8 = img.astype(_np.uint8)
    lab = _cv2.cvtColor(img_u8, _cv2.COLOR_RGB2LAB)
    clahe = _cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    l_orig = lab[:, :, 0].copy()
    lab[:, :, 0] = clahe.apply(l_orig)
    # Blend L channel back using strength
    lab_blended = lab.copy()
    lab_blended[:, :, 0] = (l_orig + strength * (lab[:, :, 0].astype(_np.float32) - l_orig.astype(_np.float32))).clip(0, 255).astype(_np.uint8)
    img = _cv2.cvtColor(lab_blended, _cv2.COLOR_LAB2RGB).astype(_np.float32)

    # ── Step 3: Auto saturation boost (HSV, ×1.15) ──────────────────────────
    img_u8 = img.astype(_np.uint8)
    hsv = _cv2.cvtColor(img_u8, _cv2.COLOR_RGB2HSV).astype(_np.float32)
    s_orig = hsv[:, :, 1].copy()
    s_boosted = _np.clip(s_orig * 1.15, 0, 255)
    hsv[:, :, 1] = s_orig + strength * (s_boosted - s_orig)
    hsv = hsv.clip(0, 255).astype(_np.uint8)
    img = _cv2.cvtColor(hsv, _cv2.COLOR_HSV2RGB).astype(_np.float32)

    # ── Step 4: Mild unsharp mask (sigma=1.0, delta weight=0.3) ─────────────
    img_u8 = img.astype(_np.uint8)
    blurred = _cv2.GaussianBlur(img_u8, (0, 0), sigmaX=1.0)
    sharpness_delta = img_u8.astype(_np.float32) - blurred.astype(_np.float32)
    sharpened = img_u8.astype(_np.float32) + 0.3 * sharpness_delta * strength
    img = sharpened.clip(0, 255)

    # Encode result as PNG
    result_pil = _Image.fromarray(img.astype(_np.uint8), mode="RGB")
    buf = _io.BytesIO()
    result_pil.save(buf, format="PNG")
    return buf.getvalue()


@router.post("/enhance")
async def enhance(req: EnhanceRequest):
    """
    Non-AI image enhancement: auto white balance, CLAHE, saturation boost,
    and unsharp mask. Each step is blended proportionally to `strength` (0–1).
    """
    try:
        image_bytes = _decode(req.image)
        result = await asyncio.get_event_loop().run_in_executor(
            None, _enhance_image, image_bytes, req.strength
        )
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


# ─── Subject replace ─────────────────────────────────────────────────────────

class ExtractSubjectRequest(BaseModel):
    image: str  # base64


class ReplaceSubjectRequest(BaseModel):
    background_image: str         # base64 — image whose background we keep
    subject_image: str            # base64 — image whose subject we extract
    mask: Optional[str] = None    # base64 — white = where the subject should land
    match_colors: bool = True     # blend subject color stats toward background


def _extract_subject_bytes(image_bytes: bytes) -> bytes:
    """Remove background from image using rembg; return RGBA PNG bytes."""
    if rembg_available():
        return remove_background_rembg(image_bytes)
    raise RuntimeError(
        "rembg is not installed. Run: pip install rembg  (or add it to requirements.txt)"
    )


def _color_transfer_lab(subj_rgba: "Image", bg_rgb: "Image", blend: float = 0.45) -> "Image":
    """
    Partial LAB color transfer: nudge subject color statistics 'blend' fraction
    toward the background's statistics so it looks like it belongs in the scene.
    """
    import cv2
    import numpy as np
    from PIL import Image

    src_arr = np.array(subj_rgba.convert("RGB"), dtype=np.float32)
    tgt_arr = np.array(bg_rgb.convert("RGB"), dtype=np.float32)

    alpha = np.array(subj_rgba.split()[3])
    subject_mask = alpha > 10

    if not subject_mask.any():
        return subj_rgba

    src_lab = cv2.cvtColor(src_arr.astype(np.uint8), cv2.COLOR_RGB2LAB).astype(np.float32)
    tgt_lab = cv2.cvtColor(tgt_arr.astype(np.uint8), cv2.COLOR_RGB2LAB).astype(np.float32)

    for ch in range(3):
        src_ch = src_lab[:, :, ch]
        src_pixels = src_ch[subject_mask]
        tgt_pixels = tgt_lab[:, :, ch].flatten()

        src_mean, src_std = float(src_pixels.mean()), float(src_pixels.std()) + 1e-6
        tgt_mean, tgt_std = float(tgt_pixels.mean()), float(tgt_pixels.std()) + 1e-6

        adjusted_std = src_std + blend * (tgt_std - src_std)
        adjusted = (src_ch - src_mean) * (adjusted_std / src_std) + src_mean + blend * (tgt_mean - src_mean)
        src_lab[:, :, ch] = np.clip(adjusted, 0, 255)

    result_rgb = cv2.cvtColor(src_lab.astype(np.uint8), cv2.COLOR_LAB2RGB)
    r, g, b = result_rgb[:, :, 0], result_rgb[:, :, 1], result_rgb[:, :, 2]
    return Image.merge("RGBA", [
        Image.fromarray(r), Image.fromarray(g),
        Image.fromarray(b), Image.fromarray(alpha),
    ])


def _do_replace_subject(
    bg_bytes: bytes,
    subj_bytes: bytes,
    mask_bytes: Optional[bytes],
    match_colors: bool,
) -> bytes:
    """Core compositing: extract subject → scale → color-match → paste onto background."""
    import numpy as np
    from PIL import Image

    bg_img = Image.open(BytesIO(bg_bytes)).convert("RGBA")

    subj_rgba = Image.open(BytesIO(_extract_subject_bytes(subj_bytes))).convert("RGBA")

    # Determine target placement bounding box from mask or full canvas
    if mask_bytes:
        mask_img = Image.open(BytesIO(mask_bytes)).convert("L")
        if mask_img.size != bg_img.size:
            mask_img = mask_img.resize(bg_img.size, Image.LANCZOS)
        mask_arr = np.array(mask_img)
        ys, xs = np.where(mask_arr > 128)
    else:
        mask_img = None
        mask_arr = None
        ys, xs = np.array([]), np.array([])

    if len(xs) > 0:
        minx, maxx = int(xs.min()), int(xs.max())
        miny, maxy = int(ys.min()), int(ys.max())
    else:
        minx, miny = 0, 0
        maxx, maxy = bg_img.width - 1, bg_img.height - 1

    target_w = maxx - minx + 1
    target_h = maxy - miny + 1

    # Scale subject to fit target area, preserving aspect ratio
    sw, sh = subj_rgba.size
    scale = min(target_w / sw, target_h / sh)
    new_w = max(1, round(sw * scale))
    new_h = max(1, round(sh * scale))
    subj_scaled = subj_rgba.resize((new_w, new_h), Image.LANCZOS)

    # Optional color transfer to blend lighting/tone
    if match_colors:
        subj_scaled = _color_transfer_lab(subj_scaled, bg_img.convert("RGB"))

    # Center in target area
    px = minx + (target_w - new_w) // 2
    py = miny + (target_h - new_h) // 2

    result = bg_img.copy()

    if mask_img is not None and len(xs) > 0:
        # Build a full-canvas RGBA layer for the subject
        subj_canvas = Image.new("RGBA", bg_img.size, (0, 0, 0, 0))
        subj_canvas.paste(subj_scaled, (px, py), subj_scaled.split()[3])
        # Clip subject's alpha to the selection mask
        sc_arr = np.array(subj_canvas)
        sc_arr[:, :, 3] = np.minimum(sc_arr[:, :, 3], mask_arr).astype(np.uint8)
        subj_canvas = Image.fromarray(sc_arr)
        result.paste(subj_canvas, (0, 0), subj_canvas.split()[3])
    else:
        result.paste(subj_scaled, (px, py), subj_scaled.split()[3])

    out = BytesIO()
    result.convert("RGB").save(out, format="PNG")
    return out.getvalue()


@router.post("/image/extract-subject")
async def extract_subject(req: ExtractSubjectRequest):
    """
    Remove background from an image and return the subject with transparency (RGBA PNG).
    Uses rembg (AI-powered) when available.
    """
    try:
        result = await asyncio.get_event_loop().run_in_executor(
            None, _extract_subject_bytes, _decode(req.image)
        )
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/image/replace-subject")
async def replace_subject(req: ReplaceSubjectRequest):
    """
    Extract the primary subject from `subject_image` (via rembg background removal),
    scale it to fit the `mask` selection on `background_image`, apply optional LAB
    color transfer for lighting consistency, and composite the result.

    Returns the composited image as base64 PNG.
    """
    try:
        result = await asyncio.get_event_loop().run_in_executor(
            None,
            _do_replace_subject,
            _decode(req.background_image),
            _decode(req.subject_image),
            _decode(req.mask) if req.mask else None,
            req.match_colors,
        )
        return {"result": _encode(result)}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


# ─── Extract colors ───────────────────────────────────────────────────────────

class ExtractColorsRequest(BaseModel):
    image: str      # base64
    count: int = 6


def _extract_colors(image_bytes: bytes, count: int) -> list[str]:
    """
    Resize image to 150×150, k-means cluster pixels into `count` groups
    using pure numpy (no sklearn dependency), return hex strings by frequency.
    """
    import numpy as np
    from PIL import Image
    from io import BytesIO

    count = max(1, min(count, 32))

    pil    = Image.open(BytesIO(image_bytes)).convert("RGB").resize((150, 150))
    pixels = np.array(pil, dtype=np.float32).reshape(-1, 3)  # (22500, 3)
    n      = len(pixels)

    # Initialise centers with k-means++ seeding
    rng     = np.random.default_rng(42)
    centers = [pixels[rng.integers(n)]]
    for _ in range(count - 1):
        dists = np.min([np.sum((pixels - c) ** 2, axis=1) for c in centers], axis=0)
        probs = dists / dists.sum()
        centers.append(pixels[rng.choice(n, p=probs)])
    centers = np.array(centers)

    labels = np.zeros(n, dtype=np.int32)
    for _ in range(20):                         # max 20 iterations
        # Assign each pixel to nearest center
        dists  = np.sum((pixels[:, None] - centers[None]) ** 2, axis=2)  # (n, k)
        new_labels = np.argmin(dists, axis=1)
        if np.all(new_labels == labels):
            break
        labels = new_labels
        # Recompute centers
        for k in range(count):
            mask = labels == k
            if mask.any():
                centers[k] = pixels[mask].mean(axis=0)

    counts = np.bincount(labels, minlength=count)
    order  = np.argsort(-counts)

    return [
        "#{:02x}{:02x}{:02x}".format(*centers[i].astype(int).clip(0, 255))
        for i in order
    ]


@router.post("/extract-colors")
async def extract_colors(req: ExtractColorsRequest):
    """
    Extract dominant colors from an image using k-means clustering.
    Returns hex color strings sorted by frequency (most dominant first).
    """
    try:
        image_bytes = _decode(req.image)
        colors = await asyncio.get_event_loop().run_in_executor(
            None, _extract_colors, image_bytes, req.count
        )
        return {"colors": colors}
    except Exception as e:
        import traceback; traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

"""
GPU status and model management endpoints.
All under /api/gpu prefix.
"""
from fastapi import APIRouter
from pydantic import BaseModel
from typing import Optional, List
import asyncio

router = APIRouter(prefix="/api/gpu", tags=["gpu"])


@router.get("/status")
async def gpu_status():
    """
    Full GPU capability report: hardware, feature flags, VRAM budget,
    and which model was selected for each operation.
    Frontend polls this to show GPU badge and tool availability.
    """
    from app.services.gpu_detect import get_cached_gpu_info
    from app.services.local_diffusion import get_all_model_states

    info = get_cached_gpu_info()

    return {
        # Hardware
        "backend":             info.backend,
        "device_name":         info.device_name,
        "vram_total_gb":       info.vram_total_gb,
        "vram_free_gb":        info.vram_free_gb,
        "compute_capability":  info.compute_capability,
        # Feature flags
        "fp16":          info.fp16,
        "bf16":          info.bf16,
        "fp8":           info.fp8,
        "int8":          info.int8,
        "tensor_cores":  info.tensor_cores,
        "xformers":      info.xformers,
        # Derived
        "effective_vram_gb": info.effective_vram_gb,
        "tier":              info.tier,
        # Selected models per operation
        "recommended": {
            op: (
                {
                    "model_id":   spec.model_id,
                    "family":     spec.family,
                    "memory_opt": spec.memory_opt,
                    "native_res": spec.native_res,
                    "vram_fp16_gb": spec.vram_fp16_gb,
                }
                if spec else None
            )
            for op, spec in info.recommended.items()
        },
        "pipeline_states": get_all_model_states(),
        "warnings":    info.warnings,
        "capabilities": info.capabilities,
    }


class PrefetchRequest(BaseModel):
    operations: Optional[List[str]] = None


@router.post("/prefetch")
async def prefetch_models(req: PrefetchRequest = PrefetchRequest()):
    """
    Eagerly load pipelines into GPU memory for the requested operations.
    Returns immediately; poll /api/gpu/prefetch-status for progress.
    Default: inpaint, txt2img, img2img.
    """
    ops = req.operations or ["inpaint", "txt2img", "img2img"]
    valid = {"inpaint", "txt2img", "img2img", "outpaint", "upscale"}
    ops = [op for op in ops if op in valid]

    from app.services.local_diffusion import get_local_diffusion_provider
    provider = get_local_diffusion_provider()

    async def _prefetch():
        for op in ops:
            try:
                await provider._get_pipeline(op)
                print(f"[gpu] Prefetch complete: {op}")
            except Exception as exc:
                print(f"[gpu] Prefetch failed for {op}: {exc}")

    asyncio.create_task(_prefetch())
    return {"status": "prefetch_started", "operations": ops}


@router.get("/prefetch-status")
async def prefetch_status():
    """Poll model download / load progress."""
    from app.services.local_diffusion import get_all_model_states
    return {"models": get_all_model_states()}

"""
SAM (Segment Anything Model) service.

Auto-downloads the ViT-B checkpoint (~375 MB) on first use.
Caches the loaded model in memory; re-uses predictor across calls.

Prediction API:
  predict_points(image_bytes, points, labels) -> mask_bytes (PNG, white=selected)
  points: list of (x, y) in original image pixels
  labels: list of 1 (include) or 0 (exclude), same length as points
"""

import asyncio
import io
import os
import urllib.request
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

import numpy as np
from PIL import Image

# ── Model download ────────────────────────────────────────────────────────────

SAM_DIR      = Path("/app/data/models/sam")
SAM_FILENAME = "sam_vit_b_01ec64.pth"
SAM_URL      = f"https://dl.fbaipublicfiles.com/segment_anything/{SAM_FILENAME}"
SAM_PATH     = SAM_DIR / SAM_FILENAME


class SamInstallState(str, Enum):
    idle        = "idle"
    downloading = "downloading"
    done        = "done"
    failed      = "failed"


@dataclass
class SamInstallStatus:
    state:    SamInstallState = SamInstallState.idle
    progress: int             = 0
    message:  str             = ""
    error:    str             = ""


_install_status = SamInstallStatus()
_install_lock   = asyncio.Lock()


def get_install_status() -> dict:
    s = _install_status
    return {"state": s.state.value, "progress": s.progress,
            "message": s.message, "error": s.error}


def sam_model_available() -> bool:
    return SAM_PATH.exists() and SAM_PATH.stat().st_size > 100_000_000


async def ensure_sam_installed() -> bool:
    """Download SAM ViT-B checkpoint if not present. Returns True on success."""
    global _install_status

    if sam_model_available():
        _install_status = SamInstallStatus(state=SamInstallState.done, progress=100,
                                           message="SAM model ready.")
        return True

    async with _install_lock:
        if sam_model_available():
            _install_status = SamInstallStatus(state=SamInstallState.done, progress=100,
                                               message="SAM model ready.")
            return True

        if _install_status.state == SamInstallState.downloading:
            return False

        try:
            SAM_DIR.mkdir(parents=True, exist_ok=True)
            _install_status = SamInstallStatus(
                state=SamInstallState.downloading, progress=0,
                message="Downloading SAM ViT-B model (~375 MB)…",
            )

            def _download():
                def _progress(count, block, total):
                    if total > 0:
                        _install_status.progress = min(99, int(count * block * 99 / total))
                tmp = SAM_PATH.with_suffix(".tmp")
                urllib.request.urlretrieve(SAM_URL, tmp, _progress)
                tmp.rename(SAM_PATH)

            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, _download)

            _install_status = SamInstallStatus(state=SamInstallState.done, progress=100,
                                               message="SAM model ready.")
            return True

        except Exception as exc:
            _install_status = SamInstallStatus(
                state=SamInstallState.failed, error=str(exc),
                message="SAM download failed.",
            )
            print(f"[sam] Download failed: {exc}")
            return False


# ── Model cache ───────────────────────────────────────────────────────────────

_predictor = None
_predictor_lock = asyncio.Lock()


def _load_predictor():
    """Load SAM model and return a SamPredictor. Called in thread pool."""
    global _predictor
    if _predictor is not None:
        return _predictor

    import torch
    from segment_anything import sam_model_registry, SamPredictor

    if torch.cuda.is_available():
        device = "cuda"
    elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        device = "mps"
    else:
        device = "cpu"

    print(f"[sam] Loading SAM ViT-B on {device}…")
    sam = sam_model_registry["vit_b"](checkpoint=str(SAM_PATH))
    sam.to(device)
    _predictor = SamPredictor(sam)
    print("[sam] Model loaded.")
    return _predictor


# ── Prediction ────────────────────────────────────────────────────────────────

def _predict_sync(image_bytes: bytes,
                  points: list[tuple[int, int]],
                  labels: list[int]) -> bytes:
    """
    Run SAM prediction synchronously (call via run_in_executor).
    Returns PNG bytes: white = selected, black = background.
    """
    predictor = _load_predictor()

    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    img_array = np.array(image)

    predictor.set_image(img_array)

    pt_array  = np.array(points, dtype=np.float32)   # [[x, y], ...]
    lbl_array = np.array(labels, dtype=np.int32)      # [1=fg, 0=bg, ...]

    masks, scores, _ = predictor.predict(
        point_coords=pt_array,
        point_labels=lbl_array,
        multimask_output=True,
    )

    # Pick the highest-confidence mask
    best = masks[int(np.argmax(scores))]  # bool array H×W

    mask_img = Image.fromarray((best * 255).astype(np.uint8), mode="L")
    buf = io.BytesIO()
    mask_img.save(buf, format="PNG")
    return buf.getvalue()


async def predict_points(image_bytes: bytes,
                         points: list[tuple[int, int]],
                         labels: list[int]) -> bytes:
    """Async wrapper for SAM point prediction."""
    if not sam_model_available():
        ok = await ensure_sam_installed()
        if not ok:
            raise RuntimeError("SAM model not available.")
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _predict_sync, image_bytes, points, labels)

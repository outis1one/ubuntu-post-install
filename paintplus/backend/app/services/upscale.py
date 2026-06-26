"""
Upscale service — auto-detects best available method and runs it.
Auto-installs Real-ESRGAN NCNN Vulkan binary when Vulkan GPU is available.
Skips NCNN on headless/CPU-only machines and uses PyTorch CPU or Lanczos instead.

Priority (auto mode):
  1. Real-ESRGAN PyTorch + CUDA GPU       — fastest, best quality
  2. Real-ESRGAN PyTorch + Apple MPS       — fast on Apple Silicon
  3. Real-ESRGAN NCNN Vulkan binary        — fast on any Vulkan GPU
  4. Real-ESRGAN PyTorch CPU               — AI quality, slow (~1-3 min)
  5. Lanczos                               — always available, instant

Capability probe is run once at first call and cached.
NCNN binary is auto-downloaded only when Vulkan is detected.
Set REALESRGAN_NCNN=force env var to override the Vulkan check.
"""

import asyncio
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from dataclasses import dataclass
from enum import Enum
from io import BytesIO
from pathlib import Path
from typing import Optional

from PIL import Image

# ── NCNN auto-install ─────────────────────────────────────────────────────────

NCNN_DEST_DIR = Path("/app/data/models/realesrgan")
NCNN_VERSION  = "v0.2.5.0"
NCNN_BASE_URL = f"https://github.com/xinntao/Real-ESRGAN/releases/download/{NCNN_VERSION}"

_PLATFORM_ZIP = {
    "linux":   f"realesrgan-ncnn-vulkan-{NCNN_VERSION}-ubuntu.zip",
    "darwin":  f"realesrgan-ncnn-vulkan-{NCNN_VERSION}-macos.zip",
    "win32":   f"realesrgan-ncnn-vulkan-{NCNN_VERSION}-windows.zip",
    "windows": f"realesrgan-ncnn-vulkan-{NCNN_VERSION}-windows.zip",
}


class InstallState(str, Enum):
    idle        = "idle"
    skipped     = "skipped"     # headless / no Vulkan
    downloading = "downloading"
    extracting  = "extracting"
    verifying   = "verifying"
    done        = "done"
    failed      = "failed"


@dataclass
class InstallStatus:
    state:    InstallState = InstallState.idle
    progress: int          = 0   # 0-100
    message:  str          = ""
    error:    str          = ""


_install_status = InstallStatus()
_install_lock   = asyncio.Lock()


def get_install_status() -> dict:
    s = _install_status
    return {
        "state":    s.state.value,
        "progress": s.progress,
        "message":  s.message,
        "error":    s.error,
    }


def _ncnn_binary_name() -> str:
    return "realesrgan-ncnn-vulkan.exe" if "win" in sys.platform.lower() else "realesrgan-ncnn-vulkan"


def _vulkan_available() -> bool:
    """
    Check whether a Vulkan-capable GPU is accessible.
    Returns True if confident a GPU with Vulkan exists; False on headless/CPU-only.
    Set REALESRGAN_NCNN=force to bypass this check.
    """
    if os.environ.get("REALESRGAN_NCNN", "").lower() == "force":
        return True

    plat = sys.platform.lower()

    if plat == "linux":
        # DRI render nodes exist when a GPU is present and drivers loaded
        dri = Path("/dev/dri")
        if dri.exists() and list(dri.glob("renderD*")):
            return True
        # Fallback: vulkaninfo (not always installed)
        if shutil.which("vulkaninfo"):
            r = subprocess.run(["vulkaninfo", "--summary"],
                               capture_output=True, timeout=5)
            if r.returncode == 0 and b"GPU" in r.stdout:
                return True
        return False

    if plat == "darwin":
        # macOS with Metal/MPS — Vulkan via MoltenVK always present on Apple Silicon/modern Intel
        return True

    if "win" in plat:
        # Windows always has a display adapter; assume Vulkan available
        return True

    return False


def _test_ncnn_binary(binary_path: Path) -> bool:
    """Run binary with --help to confirm it actually works (Vulkan loads ok)."""
    try:
        r = subprocess.run(
            [str(binary_path), "--help"],
            capture_output=True, timeout=15,
        )
        # NCNN binary exits 255 for --help but prints usage; that's fine.
        # A Vulkan init failure produces "no vulkan device" on stderr.
        stderr = r.stderr.decode(errors="replace").lower()
        if "no vulkan" in stderr or "failed to create" in stderr:
            return False
        return True
    except Exception:
        return False


async def ensure_ncnn_installed() -> Optional[Path]:
    """
    Check for Vulkan, then download+install the NCNN binary if needed.
    Skips silently on headless/CPU-only machines.
    Returns binary Path on success, None otherwise.
    """
    global _install_status

    binary_path = NCNN_DEST_DIR / _ncnn_binary_name()

    # Already installed — quick verify it still works
    if binary_path.exists() and os.access(binary_path, os.X_OK):
        loop = asyncio.get_event_loop()
        ok = await loop.run_in_executor(None, _test_ncnn_binary, binary_path)
        if ok:
            _install_status = InstallStatus(state=InstallState.done, progress=100,
                                            message="Already installed.")
            return binary_path
        else:
            # Binary exists but Vulkan broken — treat as headless
            _install_status = InstallStatus(
                state=InstallState.skipped,
                message="Vulkan unavailable — skipping NCNN (using PyTorch CPU or Lanczos).",
            )
            return None

    async with _install_lock:
        # Re-check after lock
        if binary_path.exists() and os.access(binary_path, os.X_OK):
            _install_status = InstallStatus(state=InstallState.done, progress=100,
                                            message="Already installed.")
            return binary_path

        if _install_status.state in (InstallState.downloading, InstallState.extracting,
                                     InstallState.verifying):
            return None  # already running

        # Check Vulkan before downloading anything
        loop = asyncio.get_event_loop()
        has_vulkan = await loop.run_in_executor(None, _vulkan_available)
        if not has_vulkan:
            _install_status = InstallStatus(
                state=InstallState.skipped,
                message="No Vulkan GPU detected — skipping NCNN install. "
                        "AI upscaling via PyTorch CPU or set REALESRGAN_NCNN=force to override.",
            )
            print("[upscale] Headless/no-Vulkan detected — skipping NCNN download.")
            return None

        plat = sys.platform.lower()
        zip_name = _PLATFORM_ZIP.get(plat)
        if not zip_name:
            _install_status = InstallStatus(
                state=InstallState.failed,
                error=f"Unsupported platform: {plat}",
            )
            return None

        url = f"{NCNN_BASE_URL}/{zip_name}"

        try:
            NCNN_DEST_DIR.mkdir(parents=True, exist_ok=True)
            zip_path = NCNN_DEST_DIR / zip_name

            # Download
            _install_status = InstallStatus(
                state=InstallState.downloading, progress=0,
                message=f"Downloading Real-ESRGAN NCNN {NCNN_VERSION}…",
            )

            def _do_download():
                def _progress(count, block, total):
                    if total > 0:
                        _install_status.progress = min(85, int(count * block * 85 / total))
                urllib.request.urlretrieve(url, zip_path, _progress)

            await loop.run_in_executor(None, _do_download)

            # Extract
            _install_status.state    = InstallState.extracting
            _install_status.progress = 88
            _install_status.message  = "Extracting…"

            def _do_extract():
                with zipfile.ZipFile(zip_path, "r") as zf:
                    zf.extractall(NCNN_DEST_DIR)
                found = list(NCNN_DEST_DIR.rglob(_ncnn_binary_name()))
                if not found:
                    raise FileNotFoundError(f"Binary not found after extract: {_ncnn_binary_name()}")
                extracted = found[0]
                if extracted != binary_path:
                    extracted.rename(binary_path)
                if "win" not in sys.platform.lower():
                    binary_path.chmod(
                        binary_path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH
                    )
                zip_path.unlink(missing_ok=True)

            await loop.run_in_executor(None, _do_extract)

            # Verify binary actually works
            _install_status.state    = InstallState.verifying
            _install_status.progress = 95
            _install_status.message  = "Verifying Vulkan…"

            ok = await loop.run_in_executor(None, _test_ncnn_binary, binary_path)
            if not ok:
                binary_path.unlink(missing_ok=True)
                _install_status = InstallStatus(
                    state=InstallState.skipped,
                    message="Binary installed but Vulkan unavailable at runtime — "
                            "falling back to PyTorch CPU / Lanczos.",
                )
                print("[upscale] NCNN binary installed but Vulkan check failed — skipping.")
                return None

            _install_status = InstallStatus(
                state=InstallState.done, progress=100,
                message=f"Real-ESRGAN NCNN installed: {binary_path}",
            )
            invalidate_caps_cache()
            return binary_path

        except Exception as exc:
            _install_status = InstallStatus(
                state=InstallState.failed,
                error=str(exc),
                message="Installation failed.",
            )
            print(f"[upscale] NCNN auto-install failed: {exc}")
            return None


# ── Capability detection ──────────────────────────────────────────────────────

_caps: Optional[dict] = None


def probe_upscale_capabilities() -> dict:
    """Detect available upscaling methods. Cached after first call."""
    global _caps
    if _caps is not None:
        return _caps

    caps = {
        "lanczos": True,
        "realesrgan_pytorch": False,
        "realesrgan_pytorch_device": None,
        "realesrgan_ncnn": False,
        "realesrgan_ncnn_path": None,
        "recommended": "lanczos",
        "recommended_label": "Lanczos (no AI upscaler found)",
        "methods": ["lanczos"],
        "ncnn_install_status": get_install_status(),
    }

    # ── PyTorch path ──────────────────────────────────────────────────────────
    pytorch_device = None
    try:
        import torch
        if torch.cuda.is_available():
            pytorch_device = "cuda"
        elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            pytorch_device = "mps"
        else:
            pytorch_device = "cpu"
    except ImportError:
        pass

    if pytorch_device:
        try:
            import realesrgan        # noqa: F401
            from basicsr.archs.rrdbnet_arch import RRDBNet  # noqa: F401
            caps["realesrgan_pytorch"] = True
            caps["realesrgan_pytorch_device"] = pytorch_device
            caps["methods"].append("realesrgan_pytorch")
        except ImportError:
            pass

    # ── NCNN Vulkan binary ────────────────────────────────────────────────────
    ncnn_path = _find_ncnn_binary()
    if ncnn_path:
        caps["realesrgan_ncnn"] = True
        caps["realesrgan_ncnn_path"] = str(ncnn_path)
        caps["methods"].append("realesrgan_ncnn")

    # ── Pick recommended ──────────────────────────────────────────────────────
    if caps["realesrgan_pytorch"] and pytorch_device in ("cuda", "mps"):
        device_label = "CUDA GPU" if pytorch_device == "cuda" else "Apple Silicon"
        caps["recommended"] = "realesrgan_pytorch"
        caps["recommended_label"] = f"Real-ESRGAN ({device_label})"
    elif caps["realesrgan_ncnn"]:
        caps["recommended"] = "realesrgan_ncnn"
        caps["recommended_label"] = "Real-ESRGAN NCNN (Vulkan)"
    elif caps["realesrgan_pytorch"] and pytorch_device == "cpu":
        caps["recommended"] = "realesrgan_pytorch"
        caps["recommended_label"] = "Real-ESRGAN (CPU — may be slow)"
    else:
        install_state = _install_status.state
        if install_state in (InstallState.downloading, InstallState.extracting, InstallState.verifying):
            caps["recommended_label"] = "Lanczos (AI upscaler installing…)"
        elif install_state == InstallState.skipped:
            caps["recommended_label"] = "Lanczos (headless — no Vulkan GPU)"
        else:
            caps["recommended_label"] = "Lanczos (no AI upscaler found)"

    _caps = caps
    return caps


def _find_ncnn_binary() -> Optional[Path]:
    found = shutil.which("realesrgan-ncnn-vulkan")
    if found:
        return Path(found)
    candidates = [
        NCNN_DEST_DIR / _ncnn_binary_name(),
        Path("/usr/local/bin/realesrgan-ncnn-vulkan"),
        Path.home() / ".local/bin/realesrgan-ncnn-vulkan",
        Path(r"C:/realesrgan-ncnn-vulkan/realesrgan-ncnn-vulkan.exe"),
        Path("/opt/homebrew/bin/realesrgan-ncnn-vulkan"),
    ]
    for p in candidates:
        if p.exists() and os.access(p, os.X_OK):
            return p
    return None


def invalidate_caps_cache():
    global _caps
    _caps = None


# ── Upscale implementations ───────────────────────────────────────────────────

def _to_png_bytes(img: Image.Image) -> bytes:
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def upscale_lanczos(image: Image.Image, scale: float) -> tuple[bytes, str]:
    new_w = round(image.width * scale)
    new_h = round(image.height * scale)
    result = image.resize((new_w, new_h), Image.Resampling.LANCZOS)
    return _to_png_bytes(result), "lanczos"


def upscale_realesrgan_pytorch(image: Image.Image, scale: float) -> tuple[bytes, str]:
    import torch
    from basicsr.archs.rrdbnet_arch import RRDBNet
    from realesrgan import RealESRGANer

    caps = probe_upscale_capabilities()
    device = caps.get("realesrgan_pytorch_device", "cpu")

    model_scale = 2 if scale <= 2.5 else 4
    model = RRDBNet(
        num_in_ch=3, num_out_ch=3, num_feat=64,
        num_block=23, num_grow_ch=32, scale=model_scale
    )

    model_dir = Path("/app/data/models/realesrgan")
    model_dir.mkdir(parents=True, exist_ok=True)
    model_path = model_dir / f"RealESRGAN_x{model_scale}plus.pth"
    if not model_path.exists():
        model_path = None

    upsampler = RealESRGANer(
        scale=model_scale,
        model_path=str(model_path) if model_path else None,
        model=model,
        tile=512,
        tile_pad=10,
        pre_pad=0,
        half=(device == "cuda"),
        device=torch.device(device),
    )

    import numpy as np
    img_bgr = np.array(image)[:, :, ::-1].copy()
    enhanced, _ = upsampler.enhance(img_bgr, outscale=scale)
    result = Image.fromarray(enhanced[:, :, ::-1])
    return _to_png_bytes(result), f"realesrgan_pytorch_{device}"


def upscale_realesrgan_ncnn(image: Image.Image, scale: float) -> tuple[bytes, str]:
    caps = probe_upscale_capabilities()
    binary = caps.get("realesrgan_ncnn_path")
    if not binary:
        raise RuntimeError("realesrgan-ncnn-vulkan binary not found")

    model_scale = 4 if scale > 2.5 else 2
    target_w = round(image.width * scale)
    target_h = round(image.height * scale)

    with tempfile.TemporaryDirectory() as tmpdir:
        in_path  = Path(tmpdir) / "input.png"
        out_path = Path(tmpdir) / "output.png"
        image.save(in_path, format="PNG")

        cmd = [
            binary,
            "-i", str(in_path), "-o", str(out_path),
            "-s", str(model_scale), "-n", f"realesrgan-x{model_scale}plus", "-f", "png",
        ]
        r = subprocess.run(cmd, capture_output=True, timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f"realesrgan-ncnn-vulkan failed: {r.stderr.decode()}")

        result = Image.open(out_path).convert("RGB")
        if result.width != target_w or result.height != target_h:
            result = result.resize((target_w, target_h), Image.Resampling.LANCZOS)

    return _to_png_bytes(result), "realesrgan_ncnn"


# ── Public entry point ────────────────────────────────────────────────────────

def upscale_sync(image: Image.Image, scale: float, method: str = "auto") -> tuple[bytes, str]:
    """Upscale synchronously. Returns (png_bytes, method_label)."""
    caps = probe_upscale_capabilities()

    if method == "auto":
        method = caps["recommended"]

    if method == "realesrgan_pytorch":
        if caps["realesrgan_pytorch"]:
            try:
                return upscale_realesrgan_pytorch(image, scale)
            except Exception as e:
                print(f"Real-ESRGAN PyTorch failed, falling back: {e}")
        if caps["realesrgan_ncnn"]:
            try:
                return upscale_realesrgan_ncnn(image, scale)
            except Exception as e:
                print(f"Real-ESRGAN NCNN fallback failed: {e}")
        return upscale_lanczos(image, scale)

    if method == "realesrgan_ncnn":
        if caps["realesrgan_ncnn"]:
            try:
                return upscale_realesrgan_ncnn(image, scale)
            except Exception as e:
                print(f"Real-ESRGAN NCNN failed, falling back: {e}")
        if caps["realesrgan_pytorch"]:
            try:
                return upscale_realesrgan_pytorch(image, scale)
            except Exception as e:
                print(f"Real-ESRGAN PyTorch fallback failed: {e}")
        return upscale_lanczos(image, scale)

    return upscale_lanczos(image, scale)


async def upscale_image(image: Image.Image, scale: float, method: str = "auto") -> tuple[bytes, str]:
    """Async wrapper — runs upscale in thread pool."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, upscale_sync, image, scale, method)

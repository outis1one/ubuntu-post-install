"""
GPU capability detection and per-operation model selection.

Probes the actual GPU — VRAM (total + free), CUDA compute capability, and
feature flags (fp16, bf16, fp8, int8, tensor cores) — then selects the
highest-quality model that fits for each operation.

Model selection ladder (txt2img):
  eff_vram ≥ 20 GB → FLUX.1-schnell (no offload)
  eff_vram ≥ 10 GB → FLUX.1-schnell (model_cpu_offload, 2–3× slower but fits)
  eff_vram ≥ 7.5 GB → SDXL base
  eff_vram ≥ 5.5 GB → SDXL base + attention slicing
  eff_vram ≥ 4.0 GB → SDXL + model_cpu_offload  (GTX 1060 6 GB, Quadro 6 GB)
  eff_vram ≥ 3.5 GB → Stable Diffusion 2.1
  eff_vram ≥ 2.5 GB → SD 2.1-base + attention slicing
  eff_vram ≥ 1.7 GB → Stable Diffusion 1.5
  otherwise          → SD 1.5 + sequential CPU offload

Inpaint always uses SDXL/SD-family (no FLUX inpaint pipeline yet).
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass, field
from typing import Optional


# ── Model specification ───────────────────────────────────────────────────────

@dataclass
class ModelSpec:
    """Everything needed to load and run one diffusion pipeline."""
    model_id: str
    family: str       # sd15 | sd2x | sdxl | flux
    memory_opt: str   # none | attention_slicing | model_cpu_offload | sequential_cpu_offload
    native_res: int   # 512 | 768 | 1024
    vram_fp16_gb: float  # approx VRAM needed in fp16, no memory opts


# ── GPU capability record ─────────────────────────────────────────────────────

@dataclass
class GpuCapabilities:
    # Hardware
    backend: str                  # cuda | mps | cpu
    device_name: str
    vram_total_gb: float
    vram_free_gb: float
    compute_capability: str       # "8.6", "7.5", "6.1" …
    cc_major: int
    cc_minor: int

    # Feature flags derived from compute capability
    fp16: bool          # reliable fp16  (CC ≥ 6.0; CC 5.x works but slower)
    bf16: bool          # native bf16    (CC ≥ 8.0)
    fp8: bool           # native fp8     (CC ≥ 8.9, Ada / Hopper)
    int8: bool          # efficient int8 (CC ≥ 7.0, needed for bitsandbytes)
    tensor_cores: bool  # tensor cores   (CC ≥ 7.0, Volta+)
    xformers: bool      # xformers installed (reduces attention VRAM ~20-30%)

    # Derived budget
    effective_vram_gb: float  # free VRAM after overhead, halved if fp32-only

    # Human-readable tier label
    tier: str  # flux_full | flux_offload | sdxl | sdxl_low | sdxl_offload | sd2x | sd2x_low | sd15 | minimal

    # Best model per operation
    recommended: dict[str, Optional[ModelSpec]]

    # Metadata
    warnings: list[str]
    capabilities: list[str]


# ── Detection ─────────────────────────────────────────────────────────────────

def detect_gpu() -> GpuCapabilities:
    """Probe the GPU, return a fully populated GpuCapabilities."""
    try:
        import torch

        if torch.cuda.is_available():
            props = torch.cuda.get_device_properties(0)
            free_bytes, total_bytes = torch.cuda.mem_get_info(0)
            vram_total = total_bytes / (1024 ** 3)
            vram_free  = free_bytes  / (1024 ** 3)
            cc = f"{props.major}.{props.minor}"
            major, minor = props.major, props.minor

            fp16         = major >= 6          # Pascal and newer have good fp16
            bf16         = major >= 8          # Ampere A100 / RTX 3000+
            fp8          = major > 8 or (major == 8 and minor >= 9)  # Ada / Hopper
            int8         = major >= 7          # Volta+
            tensor_cores = major >= 7

            # Pre-Pascal (Maxwell CC 5.x): fp16 works but throughput is lower than fp32
            # on some Maxwell cards. Flag it so memory opt logic can account for it.
            xf = _xformers_available()

            # Subtract driver/CUDA context overhead from free VRAM
            overhead_gb = 0.4
            eff = max(0.0, vram_free - overhead_gb)
            if not fp16:
                eff /= 2.0  # fp32 weights are 2× larger

            tier = _tier_label(eff)
            warnings = _build_warnings(
                tier, vram_total, vram_free, cc, major, minor, fp16, bf16, fp8, xf
            )

            return GpuCapabilities(
                backend="cuda",
                device_name=props.name,
                vram_total_gb=round(vram_total, 1),
                vram_free_gb=round(vram_free, 1),
                compute_capability=cc,
                cc_major=major,
                cc_minor=minor,
                fp16=fp16,
                bf16=bf16,
                fp8=fp8,
                int8=int8,
                tensor_cores=tensor_cores,
                xformers=xf,
                effective_vram_gb=round(eff, 1),
                tier=tier,
                recommended=_select_all_models(eff),
                warnings=warnings,
                capabilities=_caps(tier),
            )

        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            usable_gb = _apple_usable_gb()
            eff = max(0.0, usable_gb - 0.5)
            tier = _tier_label(eff)
            return GpuCapabilities(
                backend="mps",
                device_name="Apple Silicon",
                vram_total_gb=round(usable_gb, 1),
                vram_free_gb=round(usable_gb, 1),
                compute_capability="mps",
                cc_major=0,
                cc_minor=0,
                fp16=False,   # MPS diffusion more stable in fp32
                bf16=False,
                fp8=False,
                int8=False,
                tensor_cores=False,
                xformers=False,
                effective_vram_gb=round(eff / 2, 1),  # fp32 on MPS
                tier=tier,
                recommended=_select_all_models(eff / 2),
                warnings=["Apple MPS: using fp32 (fp16 less stable). Models load slower."],
                capabilities=_caps(tier),
            )

    except ImportError:
        pass

    # CPU fallback
    return GpuCapabilities(
        backend="cpu",
        device_name="CPU (no GPU)",
        vram_total_gb=0.0,
        vram_free_gb=0.0,
        compute_capability="",
        cc_major=0, cc_minor=0,
        fp16=False, bf16=False, fp8=False, int8=False,
        tensor_cores=False, xformers=False,
        effective_vram_gb=0.0,
        tier="minimal",
        recommended=_select_all_models(0.0),
        warnings=[
            "No GPU found. Running on CPU — expect 5–30 minutes per image. "
            "Consider setting AI_PROVIDER to a remote/cloud provider instead."
        ],
        capabilities=["txt2img", "inpaint", "img2img", "outpaint"],
    )


# ── Model selection ───────────────────────────────────────────────────────────

def _select_all_models(eff_vram: float) -> dict[str, Optional[ModelSpec]]:
    return {
        "txt2img": _select_txt2img(eff_vram),
        "img2img": _select_img2img(eff_vram),
        "inpaint":  _select_inpaint(eff_vram),
        "outpaint": _select_inpaint(eff_vram),   # shares inpaint pipeline
        "upscale":  _select_upscale(eff_vram),
    }


def _select_txt2img(eff: float) -> ModelSpec:
    # FLUX.1-schnell (Apache 2.0, 4-step distilled)
    if eff >= 20.0:
        return ModelSpec("black-forest-labs/FLUX.1-schnell", "flux", "none",            1024, 20.0)
    if eff >= 10.0:
        return ModelSpec("black-forest-labs/FLUX.1-schnell", "flux", "model_cpu_offload", 1024, 20.0)
    # SDXL base
    if eff >= 7.5:
        return ModelSpec("stabilityai/stable-diffusion-xl-base-1.0", "sdxl", "none",            1024, 6.5)
    if eff >= 5.5:
        return ModelSpec("stabilityai/stable-diffusion-xl-base-1.0", "sdxl", "attention_slicing", 1024, 6.5)
    if eff >= 4.0:
        return ModelSpec("stabilityai/stable-diffusion-xl-base-1.0", "sdxl", "model_cpu_offload", 1024, 6.5)
    # SD 2.x
    if eff >= 3.5:
        return ModelSpec("stabilityai/stable-diffusion-2-1",      "sd2x", "none",            768, 3.5)
    if eff >= 2.5:
        return ModelSpec("stabilityai/stable-diffusion-2-1-base", "sd2x", "attention_slicing", 512, 3.2)
    # SD 1.5
    if eff >= 1.7:
        return ModelSpec("stable-diffusion-v1-5/stable-diffusion-v1-5", "sd15", "attention_slicing",     512, 1.7)
    return     ModelSpec("stable-diffusion-v1-5/stable-diffusion-v1-5", "sd15", "sequential_cpu_offload", 512, 1.7)


def _select_img2img(eff: float) -> ModelSpec:
    # img2img uses the same model family as txt2img
    s = _select_txt2img(eff)
    # FLUX img2img uses a different pipeline class but same model weights
    return s


def _select_inpaint(eff: float) -> ModelSpec:
    # No FLUX inpaint pipeline available yet — SDXL is the ceiling
    if eff >= 7.5:
        return ModelSpec("diffusers/stable-diffusion-xl-1.0-inpainting-0.1", "sdxl", "none",            1024, 6.5)
    if eff >= 5.5:
        return ModelSpec("diffusers/stable-diffusion-xl-1.0-inpainting-0.1", "sdxl", "attention_slicing", 1024, 6.5)
    if eff >= 4.0:
        return ModelSpec("diffusers/stable-diffusion-xl-1.0-inpainting-0.1", "sdxl", "model_cpu_offload", 1024, 6.5)
    if eff >= 3.5:
        return ModelSpec("stabilityai/stable-diffusion-2-inpainting",        "sd2x", "none",            512,  3.5)
    if eff >= 2.5:
        return ModelSpec("stabilityai/stable-diffusion-2-inpainting",        "sd2x", "attention_slicing", 512, 3.5)
    if eff >= 1.7:
        return ModelSpec("runwayml/stable-diffusion-inpainting",             "sd15", "attention_slicing",     512, 1.7)
    return     ModelSpec("runwayml/stable-diffusion-inpainting",             "sd15", "sequential_cpu_offload", 512, 1.7)


def _select_upscale(eff: float) -> Optional[ModelSpec]:
    # SD x4 upscaler — needs ~2 GB fp16 PLUS headroom for the loaded inpaint/txt2img model.
    # Only enable if eff_vram suggests room for it as a secondary pipeline.
    if eff >= 6.0:
        return ModelSpec("stabilityai/stable-diffusion-x4-upscaler", "sd2x", "attention_slicing", 512, 2.0)
    return None  # fall through to Real-ESRGAN


# ── Tier label (display only) ─────────────────────────────────────────────────

def _tier_label(eff_vram: float) -> str:
    if eff_vram >= 20:    return "flux_full"
    if eff_vram >= 10:    return "flux_offload"
    if eff_vram >= 7.5:   return "sdxl"
    if eff_vram >= 5.5:   return "sdxl_low"
    if eff_vram >= 4.0:   return "sdxl_offload"
    if eff_vram >= 3.5:   return "sd2x"
    if eff_vram >= 2.5:   return "sd2x_low"
    if eff_vram >= 1.7:   return "sd15"
    return "minimal"


def _caps(tier: str) -> list[str]:
    base = ["txt2img", "inpaint", "img2img", "outpaint"]
    if tier in ("flux_full", "flux_offload", "sdxl", "sdxl_low", "sdxl_offload"):
        return base + ["upscale_diffusion"]
    return base


# ── Warnings ──────────────────────────────────────────────────────────────────

def _build_warnings(
    tier: str, vram_total: float, vram_free: float,
    cc: str, major: int, minor: int,
    fp16: bool, bf16: bool, fp8: bool, xf: bool,
) -> list[str]:
    w = []

    if major < 5:
        w.append(
            f"GPU compute capability {cc} is not supported by PyTorch 2.x. "
            "Upgrade to a Kepler/Maxwell-era or newer GPU (CC ≥ 5.0)."
        )
    elif major < 6:
        w.append(
            f"GPU is Maxwell-era (CC {cc}). fp32 mode — models need 2× VRAM. "
            "A Pascal GTX 1000-series or newer card enables fp16."
        )
    elif not bf16 and tier in ("flux_full", "flux_offload"):
        w.append(
            f"GPU CC {cc}: FLUX runs in fp16 (bf16 needs CC ≥ 8.0). "
            "Results are still good but Ampere/Ada GPUs are faster here."
        )

    if fp8 and tier in ("flux_full", "flux_offload"):
        w.append(
            "FP8 native support detected (Ada Lovelace / Hopper). "
            "Set HF_MODEL_TXT2IMG=flux-community/flux.1-schnell-fp8 for ~40% VRAM reduction."
        )

    if tier == "minimal":
        w.append(
            f"Very low effective VRAM ({vram_free:.1f} GB free). "
            "Sequential CPU offload will be used — expect 10–30 min per image."
        )
    elif tier == "sdxl_offload":
        w.append(
            f"Limited VRAM ({vram_free:.1f} GB free). "
            "Using SDXL with model_cpu_offload — better quality than SD 2.x, ~30% slower. "
            "Install xformers or upgrade to ≥5.5 GB effective VRAM for full-speed SDXL."
        )
    elif tier in ("sd15", "sd2x_low"):
        w.append(
            f"Limited VRAM ({vram_free:.1f} GB free). "
            "Using SD 1.5/2.x. Upgrade to ≥5.5 GB free for SDXL quality."
        )

    if xf:
        w.append(
            "xformers detected — attention VRAM reduced ~20-30%. "
            "You may be able to run a higher-tier model than listed."
        )
    else:
        if tier in ("sdxl_low", "sdxl_offload", "sd2x"):
            w.append(
                "xformers not installed. Install it (pip install xformers) to reduce "
                "VRAM usage ~20-30% and potentially unlock the next model tier."
            )

    return w


# ── Helpers ───────────────────────────────────────────────────────────────────

def _xformers_available() -> bool:
    try:
        import xformers  # noqa: F401
        return True
    except ImportError:
        return False


def _apple_usable_gb() -> float:
    """Estimate GPU-usable unified memory (≈ half of total RAM)."""
    try:
        r = subprocess.run(
            ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=5
        )
        if r.returncode == 0:
            return int(r.stdout.strip()) / (1024 ** 3) / 2
    except Exception:
        pass
    return 8.0


def infer_spec_from_model_id(model_id: str) -> ModelSpec:
    """
    When the user supplies HF_MODEL_* overrides, infer the pipeline family
    from naming conventions so the correct diffusers class is chosen.
    """
    mid = model_id.lower()
    if "flux" in mid:
        return ModelSpec(model_id, "flux", "model_cpu_offload", 1024, 20.0)
    if "xl" in mid or "sdxl" in mid:
        return ModelSpec(model_id, "sdxl", "attention_slicing", 1024, 6.5)
    if any(x in mid for x in ["sd-2", "sd2", "stable-diffusion-2", "-2-", "-2inpaint"]):
        res = 512 if "base" in mid else 768
        return ModelSpec(model_id, "sd2x", "attention_slicing", res, 3.5)
    return ModelSpec(model_id, "sd15", "attention_slicing", 512, 1.7)


# ── Singleton ─────────────────────────────────────────────────────────────────

_cached: Optional[GpuCapabilities] = None


def get_cached_gpu_info() -> GpuCapabilities:
    global _cached
    if _cached is None:
        _cached = detect_gpu()
    return _cached


# Alias kept for any callers still using the old name
def get_model_ids(tier: str) -> dict:
    """Compatibility shim — returns model_id strings keyed by operation."""
    info = get_cached_gpu_info()
    return {
        op: (spec.model_id if spec else None)
        for op, spec in info.recommended.items()
    }

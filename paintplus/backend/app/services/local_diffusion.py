"""
Local GPU diffusion provider — HuggingFace Diffusers backend.

Implements RemoteAIProvider so all existing routes work unchanged.
Pipelines are lazy-loaded, cached in an LRU store, and memory-optimised
per the ModelSpec chosen by gpu_detect.

Supported model families:
  flux  → FluxPipeline / FluxImg2ImgPipeline      (FLUX.1-schnell)
  sdxl  → StableDiffusionXL*Pipeline              (SDXL base + SDXL Inpaint)
  sd2x  → StableDiffusion2*Pipeline               (SD 2.x)
  sd15  → StableDiffusionPipeline                 (SD 1.5)

Requires: diffusers>=0.28.0,<0.29.0, transformers, accelerate, safetensors
          (all in requirements.gpu.txt — pinned <0.29.0 for PyTorch 2.1.x compatibility)
"""
from __future__ import annotations

import asyncio
import threading
from collections import OrderedDict
from io import BytesIO
from typing import Optional

from PIL import Image

from app.services.gpu_detect import (
    GpuCapabilities,
    ModelSpec,
    get_cached_gpu_info,
    infer_spec_from_model_id,
)
from app.services.remote_provider import RemoteAIProvider

# ── Model state tracking ──────────────────────────────────────────────────────

_states: dict[str, dict] = {}
_states_lock = threading.Lock()


def _set_state(key: str, **kw):
    with _states_lock:
        _states.setdefault(key, {}).update(kw)


def get_all_model_states() -> list[dict]:
    with _states_lock:
        return list(_states.values())


def _make_step_cb(pipe_type: str, total_steps: int):
    """
    Returns a diffusers callback_on_step_end that writes per-step progress
    into _states so the SSE /api/generate/progress endpoint can stream it.
    Called from a thread executor — _set_state is thread-safe.
    """
    def cb(pipe, step_index: int, timestep, callback_kwargs: dict) -> dict:
        done = step_index + 1
        _set_state(pipe_type,
                   state="running",
                   step=done,
                   total_steps=total_steps,
                   progress=round(done / total_steps * 85, 1),
                   message=f"Step {done} / {total_steps}")
        return callback_kwargs
    return cb


# ── LRU pipeline cache ────────────────────────────────────────────────────────

class _PipelineCache:
    def __init__(self, maxsize: int = 2):
        self._cache: OrderedDict[str, object] = OrderedDict()
        self._maxsize = maxsize
        self._lock = asyncio.Lock()

    async def get(self, key: str):
        async with self._lock:
            if key in self._cache:
                self._cache.move_to_end(key)
                return self._cache[key]
            return None

    async def put(self, key: str, pipe: object):
        async with self._lock:
            if key in self._cache:
                self._cache.move_to_end(key)
            else:
                if len(self._cache) >= self._maxsize:
                    evicted_key, evicted = self._cache.popitem(last=False)
                    _evict(evicted, evicted_key)
                self._cache[key] = pipe


def _evict(pipe, key: str):
    try:
        import torch
        pipe.to("cpu")
        torch.cuda.empty_cache()
        print(f"[local_gpu] Evicted '{key}' from GPU cache")
    except Exception:
        pass


# ── Pipeline loading helpers ──────────────────────────────────────────────────

def _apply_hf_token():
    try:
        from app.config import settings
        if settings.hf_token:
            import huggingface_hub
            huggingface_hub.login(token=settings.hf_token, add_to_git_credential=False)
    except Exception:
        pass


def _get_spec(pipe_type: str, info: GpuCapabilities) -> ModelSpec:
    """Return the ModelSpec for a pipeline type, respecting user overrides."""
    # Map outpaint to inpaint (same pipeline)
    op_key = "inpaint" if pipe_type == "outpaint" else pipe_type
    # img2img uses same family/model as txt2img for FLUX/SDXL
    if pipe_type == "img2img" and op_key not in info.recommended:
        op_key = "txt2img"

    # User config override
    try:
        from app.config import settings
        override_map = {
            "inpaint":  settings.hf_model_inpaint,
            "outpaint": settings.hf_model_inpaint,
            "txt2img":  settings.hf_model_txt2img,
            "img2img":  settings.hf_model_img2img,
        }
        override_id = override_map.get(pipe_type, "") or ""
        if override_id:
            return infer_spec_from_model_id(override_id)
    except Exception:
        pass

    spec = info.recommended.get(op_key)
    if spec is None:
        raise RuntimeError(
            f"No model available for '{pipe_type}' at effective VRAM "
            f"{info.effective_vram_gb:.1f} GB. GPU may not have enough memory."
        )
    return spec


def _load_sd_pipeline(pipe_type: str, spec: ModelSpec, info: GpuCapabilities) -> object:
    """Load a Stable Diffusion (1.5 / 2.x / XL) pipeline."""
    import torch
    from diffusers import (
        StableDiffusionPipeline,
        StableDiffusionImg2ImgPipeline,
        StableDiffusionInpaintPipeline,
        StableDiffusionUpscalePipeline,
        StableDiffusionXLPipeline,
        StableDiffusionXLImg2ImgPipeline,
        StableDiffusionXLInpaintPipeline,
    )

    dtype = torch.float16 if info.fp16 else torch.float32
    is_xl = spec.family == "sdxl"
    kwargs: dict = {"torch_dtype": dtype}
    if not is_xl:
        kwargs["safety_checker"] = None
        kwargs["requires_safety_checker"] = False

    op_key = "inpaint" if pipe_type in ("inpaint", "outpaint") else pipe_type

    if op_key == "inpaint":
        cls = StableDiffusionXLInpaintPipeline if is_xl else StableDiffusionInpaintPipeline
    elif op_key == "txt2img":
        cls = StableDiffusionXLPipeline if is_xl else StableDiffusionPipeline
    elif op_key == "img2img":
        cls = StableDiffusionXLImg2ImgPipeline if is_xl else StableDiffusionImg2ImgPipeline
    elif op_key == "upscale":
        cls = StableDiffusionUpscalePipeline
    else:
        raise ValueError(f"Unknown SD operation: {op_key}")

    pipe = cls.from_pretrained(spec.model_id, **kwargs)
    return _apply_mem_opts(pipe, spec, info)


def _load_flux_pipeline(pipe_type: str, spec: ModelSpec, info: GpuCapabilities) -> object:
    """Load a FLUX pipeline (txt2img or img2img)."""
    import torch
    from diffusers import FluxPipeline, FluxImg2ImgPipeline

    # FLUX works best in bf16 on Ampere+; fp16 on older Turing/Pascal
    dtype = torch.bfloat16 if info.bf16 else torch.float16

    op_key = "img2img" if pipe_type == "img2img" else "txt2img"
    cls = FluxImg2ImgPipeline if op_key == "img2img" else FluxPipeline

    pipe = cls.from_pretrained(spec.model_id, torch_dtype=dtype)
    return _apply_mem_opts(pipe, spec, info)


def _apply_mem_opts(pipe, spec: ModelSpec, info: GpuCapabilities) -> object:
    """Apply memory optimisations then move pipeline to device."""
    device = info.backend
    opt = spec.memory_opt

    # VAE slicing is always beneficial (reduces VRAM for decoding large images)
    try:
        pipe.enable_vae_slicing()
    except Exception:
        pass

    # xformers memory-efficient attention
    if info.xformers and spec.family != "flux":
        try:
            pipe.enable_xformers_memory_efficient_attention()
        except Exception:
            pass

    if opt == "sequential_cpu_offload":
        # Each layer moved to GPU only during its forward pass — very VRAM-efficient
        # enable_sequential_cpu_offload() also calls .to(device) internally
        try:
            pipe.enable_sequential_cpu_offload()
        except Exception:
            pipe.to("cpu")

    elif opt == "model_cpu_offload":
        # Entire sub-models (text encoder, unet/transformer, VAE) moved between CPU/GPU
        # Faster than sequential but needs ~3-4 GB free to hold the active module
        try:
            pipe.enable_model_cpu_offload()
        except Exception:
            pipe.to(device)

    elif opt == "attention_slicing":
        try:
            pipe.enable_attention_slicing(1)
        except Exception:
            pass
        pipe.to(device)

    else:  # "none"
        pipe.to(device)

    return pipe


# ── Provider ─────────────────────────────────────────────────────────────────

class LocalDiffusionProvider(RemoteAIProvider):
    def __init__(self, max_cached_pipelines: int = 2):
        self._cache = _PipelineCache(maxsize=max_cached_pipelines)
        self._load_locks: dict[str, asyncio.Lock] = {}
        self._meta_lock = asyncio.Lock()

    @property
    def _info(self) -> GpuCapabilities:
        return get_cached_gpu_info()

    async def _lock_for(self, key: str) -> asyncio.Lock:
        async with self._meta_lock:
            if key not in self._load_locks:
                self._load_locks[key] = asyncio.Lock()
            return self._load_locks[key]

    def _load_pipeline_sync(self, pipe_type: str) -> object:
        info = self._info
        spec = _get_spec(pipe_type, info)

        _apply_hf_token()
        _set_state(pipe_type, pipeline=pipe_type, model_id=spec.model_id,
                   family=spec.family, memory_opt=spec.memory_opt,
                   state="downloading", progress=0.0,
                   message=f"Downloading {spec.model_id}…", error="")
        try:
            if spec.family == "flux":
                pipe = _load_flux_pipeline(pipe_type, spec, info)
            else:
                pipe = _load_sd_pipeline(pipe_type, spec, info)

            _set_state(pipe_type, state="ready", progress=100.0, message="Ready")
            return pipe
        except Exception as exc:
            _set_state(pipe_type, state="failed", error=str(exc), message="Load failed")
            raise

    async def _get_pipeline(self, pipe_type: str) -> object:
        cached = await self._cache.get(pipe_type)
        if cached is not None:
            return cached

        lock = await self._lock_for(pipe_type)
        async with lock:
            cached = await self._cache.get(pipe_type)
            if cached is not None:
                return cached
            loop = asyncio.get_event_loop()
            pipe = await loop.run_in_executor(None, self._load_pipeline_sync, pipe_type)
            await self._cache.put(pipe_type, pipe)
            return pipe

    # ── RemoteAIProvider ──────────────────────────────────────────────────────

    async def inpaint(self, image_bytes: bytes, mask_bytes: bytes, prompt: str, params: dict) -> bytes:
        pipe = await self._get_pipeline("inpaint")
        spec = _get_spec("inpaint", self._info)

        img  = Image.open(BytesIO(image_bytes)).convert("RGB")
        mask = Image.open(BytesIO(mask_bytes)).convert("L")
        orig = img.size
        img_r, mask_r = _resize_pair(img, mask, spec.native_res)

        steps = int(params.get("steps", 30))
        cfg   = float(params.get("cfg_scale", 7.5))
        neg   = params.get("negative_prompt", "") or None
        step_cb = _make_step_cb("inpaint", steps)

        _set_state("inpaint", state="running", step=0, total_steps=steps, progress=0, message="Starting…")

        def _run():
            try:
                return pipe(
                    prompt=prompt,
                    negative_prompt=neg,
                    image=img_r,
                    mask_image=mask_r,
                    num_inference_steps=steps,
                    guidance_scale=cfg,
                    callback_on_step_end=step_cb,
                    callback_on_step_end_tensor_inputs=["latents"],
                ).images[0].resize(orig, Image.LANCZOS)
            except TypeError:
                return pipe(
                    prompt=prompt,
                    negative_prompt=neg,
                    image=img_r,
                    mask_image=mask_r,
                    num_inference_steps=steps,
                    guidance_scale=cfg,
                ).images[0].resize(orig, Image.LANCZOS)

        result = _to_png(await asyncio.get_event_loop().run_in_executor(None, _run))
        _set_state("inpaint", state="ready", step=None, total_steps=None, progress=100, message="Ready")
        return result

    async def txt2img(self, prompt: str, width: int, height: int, params: dict) -> bytes:
        pipe = await self._get_pipeline("txt2img")
        spec = _get_spec("txt2img", self._info)

        max_dim = spec.native_res
        w = min(width,  max_dim) // 8 * 8
        h = min(height, max_dim) // 8 * 8
        seed = int(params.get("seed", 0))
        is_flux = spec.family == "flux"
        steps = 4 if is_flux else int(params.get("steps", 30))
        step_cb = _make_step_cb("txt2img", steps)

        _set_state("txt2img", state="running", step=0, total_steps=steps, progress=0, message="Starting…")

        def _run():
            import torch
            device = self._info.backend
            gen = torch.Generator(device=device).manual_seed(seed) if seed else None

            try:
                if is_flux:
                    return pipe(
                        prompt=prompt,
                        width=w, height=h,
                        num_inference_steps=steps,
                        guidance_scale=0.0,
                        max_sequence_length=256,
                        generator=gen,
                        callback_on_step_end=step_cb,
                        callback_on_step_end_tensor_inputs=["latents"],
                    ).images[0]
                else:
                    return pipe(
                        prompt=prompt,
                        negative_prompt=params.get("negative_prompt", "") or None,
                        width=w, height=h,
                        num_inference_steps=steps,
                        guidance_scale=float(params.get("cfg_scale", 7.5)),
                        generator=gen,
                        callback_on_step_end=step_cb,
                        callback_on_step_end_tensor_inputs=["latents"],
                    ).images[0]
            except TypeError:
                # Older diffusers without callback_on_step_end
                if is_flux:
                    return pipe(
                        prompt=prompt, width=w, height=h,
                        num_inference_steps=steps, guidance_scale=0.0,
                        max_sequence_length=256, generator=gen,
                    ).images[0]
                else:
                    return pipe(
                        prompt=prompt,
                        negative_prompt=params.get("negative_prompt", "") or None,
                        width=w, height=h,
                        num_inference_steps=steps,
                        guidance_scale=float(params.get("cfg_scale", 7.5)),
                        generator=gen,
                    ).images[0]

        result = _to_png(await asyncio.get_event_loop().run_in_executor(None, _run))
        _set_state("txt2img", state="ready", step=None, total_steps=None, progress=100, message="Ready")
        return result

    async def img2img(self, image_bytes: bytes, prompt: str, strength: float, params: dict) -> bytes:
        pipe = await self._get_pipeline("img2img")
        spec = _get_spec("img2img", self._info)

        img  = Image.open(BytesIO(image_bytes)).convert("RGB")
        orig = img.size
        img_r = _resize_square(img, spec.native_res)
        is_flux = spec.family == "flux"
        steps = 4 if is_flux else int(params.get("steps", 30))
        step_cb = _make_step_cb("img2img", steps)

        _set_state("img2img", state="running", step=0, total_steps=steps, progress=0, message="Starting…")

        def _run():
            try:
                if is_flux:
                    result = pipe(
                        prompt=prompt, image=img_r, strength=strength,
                        num_inference_steps=steps, guidance_scale=0.0,
                        callback_on_step_end=step_cb,
                        callback_on_step_end_tensor_inputs=["latents"],
                    ).images[0]
                else:
                    result = pipe(
                        prompt=prompt,
                        negative_prompt=params.get("negative_prompt", "") or None,
                        image=img_r, strength=strength,
                        num_inference_steps=steps,
                        guidance_scale=float(params.get("cfg_scale", 7.5)),
                        callback_on_step_end=step_cb,
                        callback_on_step_end_tensor_inputs=["latents"],
                    ).images[0]
            except TypeError:
                if is_flux:
                    result = pipe(
                        prompt=prompt, image=img_r, strength=strength,
                        num_inference_steps=steps, guidance_scale=0.0,
                    ).images[0]
                else:
                    result = pipe(
                        prompt=prompt,
                        negative_prompt=params.get("negative_prompt", "") or None,
                        image=img_r, strength=strength,
                        num_inference_steps=steps,
                        guidance_scale=float(params.get("cfg_scale", 7.5)),
                    ).images[0]
            return result.resize(orig, Image.LANCZOS)

        result = _to_png(await asyncio.get_event_loop().run_in_executor(None, _run))
        _set_state("img2img", state="ready", step=None, total_steps=None, progress=100, message="Ready")
        return result

    async def outpaint(self, image_bytes: bytes, direction: str, size: int, prompt: str) -> bytes:
        from PIL import ImageDraw

        img = Image.open(BytesIO(image_bytes)).convert("RGB")
        w, h = img.size

        positions = {
            "right":  ((w + size, h),      (0, 0),    (w, 0, w + size, h)),
            "left":   ((w + size, h),      (size, 0), (0, 0, size, h)),
            "bottom": ((w, h + size),      (0, 0),    (0, h, w, h + size)),
            "top":    ((w, h + size),      (0, size), (0, 0, w, size)),
        }
        new_size, paste_at, mask_box = positions[direction]

        expanded = Image.new("RGB", new_size, (127, 127, 127))
        expanded.paste(img, paste_at)
        mask = Image.new("L", new_size, 0)
        ImageDraw.Draw(mask).rectangle(mask_box, fill=255)

        fill_prompt = prompt or "seamless natural continuation of the scene"
        return await self.inpaint(_to_png(expanded), _to_png(mask), fill_prompt, {})

    async def health(self) -> bool:
        return True

    def capabilities(self) -> list[str]:
        return self._info.capabilities


# ── Image utilities ───────────────────────────────────────────────────────────

def _resize_pair(img: Image.Image, mask: Image.Image, target: int):
    w, h = img.size
    scale = target / max(w, h)
    nw = max(8, int(w * scale) // 8 * 8)
    nh = max(8, int(h * scale) // 8 * 8)
    return img.resize((nw, nh), Image.LANCZOS), mask.resize((nw, nh), Image.NEAREST)


def _resize_square(img: Image.Image, target: int) -> Image.Image:
    w, h = img.size
    scale = target / max(w, h)
    nw = max(8, int(w * scale) // 8 * 8)
    nh = max(8, int(h * scale) // 8 * 8)
    return img.resize((nw, nh), Image.LANCZOS)


def _to_png(img: Image.Image) -> bytes:
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# ── Singleton ─────────────────────────────────────────────────────────────────

_provider: Optional[LocalDiffusionProvider] = None


def get_local_diffusion_provider(max_pipelines: int = 2) -> LocalDiffusionProvider:
    global _provider
    if _provider is None:
        _provider = LocalDiffusionProvider(max_cached_pipelines=max_pipelines)
    return _provider


async def prefetch_model_files() -> None:
    """
    Download model weight files to HuggingFace disk cache without loading into GPU.
    Called at container startup so the first request loads from disk (fast).
    """
    from app.services.gpu_detect import get_cached_gpu_info
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        print("[local_gpu] huggingface_hub not installed — skipping model prefetch")
        return

    info = get_cached_gpu_info()
    _apply_hf_token()

    loop = asyncio.get_event_loop()
    seen: set[str] = set()

    for op, spec in info.recommended.items():
        if spec is None or spec.model_id in seen:
            continue
        seen.add(spec.model_id)

        # Apply user override if set
        try:
            from app.config import settings
            override_map = {
                "inpaint":  settings.hf_model_inpaint,
                "txt2img":  settings.hf_model_txt2img,
                "img2img":  settings.hf_model_img2img,
            }
            override = override_map.get(op, "") or ""
            if override and override not in seen:
                seen.add(override)
                spec = infer_spec_from_model_id(override)
        except Exception:
            pass

        _set_state(op, pipeline=op, model_id=spec.model_id, family=spec.family,
                   memory_opt=spec.memory_opt, state="downloading", progress=0.0,
                   message=f"Downloading {spec.model_id}…", error="")
        print(f"[local_gpu] Prefetching: {spec.model_id}")

        def _dl(model_id=spec.model_id):
            snapshot_download(
                repo_id=model_id,
                ignore_patterns=["*.msgpack", "flax_*", "tf_*", "rust_model*"],
            )

        try:
            await loop.run_in_executor(None, _dl)
            _set_state(op, state="cached", progress=100.0,
                       message="Files cached — loads into GPU on first request")
            print(f"[local_gpu] ✓ Cached: {spec.model_id}")
        except Exception as exc:
            _set_state(op, state="download_failed", error=str(exc),
                       message="Download failed — will retry on first request")
            print(f"[local_gpu] Prefetch failed for {spec.model_id}: {exc}")

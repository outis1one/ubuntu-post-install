"""
Remote AI provider abstraction.
One interface, three drivers: OpenAI, InvokeAI, ComfyUI.
Configure one provider via AI_PROVIDER in .env.
"""

from abc import ABC, abstractmethod
from typing import Optional
import httpx
import base64
import asyncio
from io import BytesIO


class RemoteAIProvider(ABC):
    @abstractmethod
    async def inpaint(self, image_bytes: bytes, mask_bytes: bytes, prompt: str, params: dict) -> bytes: ...
    @abstractmethod
    async def txt2img(self, prompt: str, width: int, height: int, params: dict) -> bytes: ...
    @abstractmethod
    async def img2img(self, image_bytes: bytes, prompt: str, strength: float, params: dict) -> bytes: ...
    @abstractmethod
    async def outpaint(self, image_bytes: bytes, direction: str, size: int, prompt: str) -> bytes: ...
    @abstractmethod
    async def health(self) -> bool: ...
    @abstractmethod
    def capabilities(self) -> list[str]: ...


class OpenAIRemoteProvider(RemoteAIProvider):
    """OpenAI image API — gpt-image-1 / dall-e-3."""

    def __init__(self, api_key: str, model: str = "dall-e-3"):
        self.api_key = api_key
        self.model = model
        self.base_url = "https://api.openai.com/v1"

    def _headers(self):
        return {"Authorization": f"Bearer {self.api_key}"}

    async def inpaint(self, image_bytes: bytes, mask_bytes: bytes, prompt: str, params: dict) -> bytes:
        async with httpx.AsyncClient(timeout=120.0) as client:
            files = {
                "image": ("image.png", image_bytes, "image/png"),
                "mask": ("mask.png", mask_bytes, "image/png"),
            }
            data = {"prompt": prompt, "n": "1", "size": "1024x1024"}
            r = await client.post(f"{self.base_url}/images/edits", files=files, data=data, headers=self._headers())
            r.raise_for_status()
            url = r.json()["data"][0]["url"]
            img_r = await client.get(url)
            img_r.raise_for_status()
            return img_r.content

    async def txt2img(self, prompt: str, width: int, height: int, params: dict) -> bytes:
        size = f"{width}x{height}" if f"{width}x{height}" in {"256x256", "512x512", "1024x1024"} else "1024x1024"
        async with httpx.AsyncClient(timeout=120.0) as client:
            data = {"model": self.model, "prompt": prompt, "n": 1, "size": size}
            r = await client.post(f"{self.base_url}/images/generations", json=data, headers=self._headers())
            r.raise_for_status()
            url = r.json()["data"][0]["url"]
            img_r = await client.get(url)
            img_r.raise_for_status()
            return img_r.content

    async def img2img(self, image_bytes: bytes, prompt: str, strength: float, params: dict) -> bytes:
        # OpenAI doesn't have img2img natively — use edits with blank mask
        from PIL import Image
        import numpy as np
        img = Image.open(BytesIO(image_bytes)).convert("RGBA")
        mask = Image.new("RGBA", img.size, (0, 0, 0, 0))
        mask_buf = BytesIO()
        mask.save(mask_buf, format="PNG")
        return await self.inpaint(image_bytes, mask_buf.getvalue(), prompt, params)

    async def outpaint(self, image_bytes: bytes, direction: str, size: int, prompt: str) -> bytes:
        from PIL import Image
        img = Image.open(BytesIO(image_bytes)).convert("RGBA")
        w, h = img.size
        directions = {"left": (size, 0), "right": (size, 0), "top": (0, size), "bottom": (0, size)}
        dw, dh = directions.get(direction, (size, 0))
        new_w, new_h = w + dw, h + dh
        canvas = Image.new("RGBA", (new_w, new_h), (0, 0, 0, 0))
        offsets = {
            "left": (size, 0), "right": (0, 0), "top": (0, size), "bottom": (0, 0)
        }
        ox, oy = offsets.get(direction, (0, 0))
        canvas.paste(img, (ox, oy))
        # mask: transparent = inpaint
        mask = Image.new("L", (new_w, new_h), 0)
        # fill the expanded region with white in mask
        import numpy as np
        mask_arr = np.zeros((new_h, new_w), dtype=np.uint8)
        if direction == "left":
            mask_arr[:, :size] = 255
        elif direction == "right":
            mask_arr[:, w:] = 255
        elif direction == "top":
            mask_arr[:size, :] = 255
        else:
            mask_arr[h:, :] = 255
        mask = Image.fromarray(mask_arr, "L")

        canvas_rgb = canvas.convert("RGB")
        img_buf = BytesIO()
        canvas_rgb.save(img_buf, format="PNG")
        mask_buf = BytesIO()
        mask.save(mask_buf, format="PNG")
        return await self.inpaint(img_buf.getvalue(), mask_buf.getvalue(), prompt, {})

    async def health(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                r = await client.get(f"{self.base_url}/models", headers=self._headers())
                return r.status_code == 200
        except Exception:
            return False

    def capabilities(self) -> list[str]:
        return ["inpaint", "txt2img", "img2img", "outpaint"]


class InvokeAIProvider(RemoteAIProvider):
    """InvokeAI REST API driver — supports Flux, SDXL, SD1.5 and more."""

    def __init__(self, base_url: str, default_model: str = "flux-dev"):
        self.base_url = base_url.rstrip("/")
        self.default_model = default_model

    async def _b64(self, data: bytes) -> str:
        return base64.b64encode(data).decode()

    async def _upload_image(self, client: httpx.AsyncClient, image_bytes: bytes, category: str = "general") -> str:
        """Upload image to InvokeAI and return image_name."""
        files = {"file": ("image.png", image_bytes, "image/png")}
        data = {"image_category": category, "is_intermediate": "false"}
        r = await client.post(f"{self.base_url}/api/v1/images/upload", files=files, data=data)
        r.raise_for_status()
        return r.json()["image_name"]

    async def _run_graph(self, client: httpx.AsyncClient, graph: dict) -> bytes:
        """Post a graph, poll for completion, return result image bytes."""
        r = await client.post(f"{self.base_url}/api/v1/queue/default/enqueue_batch",
                              json={"prepend": False, "batch": {"graph": graph, "runs": 1}})
        r.raise_for_status()
        batch_id = r.json()["batch"]["batch_id"]

        # Poll queue status
        for _ in range(180):
            await asyncio.sleep(2)
            sr = await client.get(f"{self.base_url}/api/v1/queue/default/status")
            sr.raise_for_status()
            status = sr.json()
            if status.get("queue", {}).get("completed", 0) > 0:
                break
            if status.get("queue", {}).get("failed", 0) > 0:
                raise RuntimeError("InvokeAI graph failed")

        # Fetch latest result image
        lr = await client.get(f"{self.base_url}/api/v1/images/?categories=general&limit=1&is_intermediate=false")
        lr.raise_for_status()
        items = lr.json().get("items", [])
        if not items:
            raise RuntimeError("No output image from InvokeAI")

        img_name = items[0]["image_name"]
        img_r = await client.get(f"{self.base_url}/api/v1/images/i/{img_name}/full")
        img_r.raise_for_status()
        return img_r.content

    async def inpaint(self, image_bytes: bytes, mask_bytes: bytes, prompt: str, params: dict) -> bytes:
        async with httpx.AsyncClient(timeout=300.0) as client:
            img_name = await self._upload_image(client, image_bytes)
            mask_name = await self._upload_image(client, mask_bytes, "mask")
            model = params.get("model", self.default_model)
            graph = {
                "id": "inpaint_graph",
                "nodes": {
                    "img_node": {"id": "img_node", "type": "image", "image": {"image_name": img_name}},
                    "mask_node": {"id": "mask_node", "type": "image", "image": {"image_name": mask_name}},
                    "model_node": {"id": "model_node", "type": "main_model_loader", "model": {"model_name": model, "base": "any"}},
                    "clip_skip": {"id": "clip_skip", "type": "clip_skip", "skipped_layers": 0},
                    "positive": {"id": "positive", "type": "compel", "prompt": prompt},
                    "negative": {"id": "negative", "type": "compel", "prompt": params.get("negative_prompt", "")},
                    "denoise": {
                        "id": "denoise", "type": "denoise_latents",
                        "steps": params.get("steps", 30),
                        "cfg_scale": params.get("cfg_scale", 7.5),
                        "denoising_start": 0.0, "denoising_end": 1.0,
                        "scheduler": "euler", "is_intermediate": False
                    },
                    "vae_loader": {"id": "vae_loader", "type": "vae_loader", "vae_model": {"model_name": model, "base": "any"}},
                    "img_to_latents": {"id": "img_to_latents", "type": "i2l"},
                    "latents_to_img": {"id": "latents_to_img", "type": "l2i"},
                },
                "edges": [
                    {"source": {"node_id": "model_node", "field": "unet"}, "destination": {"node_id": "denoise", "field": "unet"}},
                    {"source": {"node_id": "model_node", "field": "clip"}, "destination": {"node_id": "clip_skip", "field": "clip"}},
                    {"source": {"node_id": "clip_skip", "field": "clip"}, "destination": {"node_id": "positive", "field": "clip"}},
                    {"source": {"node_id": "clip_skip", "field": "clip"}, "destination": {"node_id": "negative", "field": "clip"}},
                    {"source": {"node_id": "positive", "field": "conditioning"}, "destination": {"node_id": "denoise", "field": "positive_conditioning"}},
                    {"source": {"node_id": "negative", "field": "conditioning"}, "destination": {"node_id": "denoise", "field": "negative_conditioning"}},
                    {"source": {"node_id": "img_node", "field": "image"}, "destination": {"node_id": "img_to_latents", "field": "image"}},
                    {"source": {"node_id": "vae_loader", "field": "vae"}, "destination": {"node_id": "img_to_latents", "field": "vae"}},
                    {"source": {"node_id": "img_to_latents", "field": "latents"}, "destination": {"node_id": "denoise", "field": "latents"}},
                    {"source": {"node_id": "mask_node", "field": "image"}, "destination": {"node_id": "denoise", "field": "mask"}},
                    {"source": {"node_id": "denoise", "field": "latents"}, "destination": {"node_id": "latents_to_img", "field": "latents"}},
                    {"source": {"node_id": "vae_loader", "field": "vae"}, "destination": {"node_id": "latents_to_img", "field": "vae"}},
                ]
            }
            return await self._run_graph(client, graph)

    async def txt2img(self, prompt: str, width: int, height: int, params: dict) -> bytes:
        async with httpx.AsyncClient(timeout=300.0) as client:
            model = params.get("model", self.default_model)
            graph = {
                "id": "txt2img_graph",
                "nodes": {
                    "model_node": {"id": "model_node", "type": "main_model_loader", "model": {"model_name": model, "base": "any"}},
                    "clip_skip": {"id": "clip_skip", "type": "clip_skip", "skipped_layers": 0},
                    "positive": {"id": "positive", "type": "compel", "prompt": prompt},
                    "negative": {"id": "negative", "type": "compel", "prompt": params.get("negative_prompt", "")},
                    "noise": {"id": "noise", "type": "noise", "width": width, "height": height, "seed": params.get("seed", 0)},
                    "denoise": {
                        "id": "denoise", "type": "denoise_latents",
                        "steps": params.get("steps", 30),
                        "cfg_scale": params.get("cfg_scale", 7.5),
                        "denoising_start": 0.0, "denoising_end": 1.0,
                        "scheduler": "euler",
                    },
                    "vae_loader": {"id": "vae_loader", "type": "vae_loader", "vae_model": {"model_name": model, "base": "any"}},
                    "latents_to_img": {"id": "latents_to_img", "type": "l2i"},
                },
                "edges": [
                    {"source": {"node_id": "model_node", "field": "unet"}, "destination": {"node_id": "denoise", "field": "unet"}},
                    {"source": {"node_id": "model_node", "field": "clip"}, "destination": {"node_id": "clip_skip", "field": "clip"}},
                    {"source": {"node_id": "clip_skip", "field": "clip"}, "destination": {"node_id": "positive", "field": "clip"}},
                    {"source": {"node_id": "clip_skip", "field": "clip"}, "destination": {"node_id": "negative", "field": "clip"}},
                    {"source": {"node_id": "positive", "field": "conditioning"}, "destination": {"node_id": "denoise", "field": "positive_conditioning"}},
                    {"source": {"node_id": "negative", "field": "conditioning"}, "destination": {"node_id": "denoise", "field": "negative_conditioning"}},
                    {"source": {"node_id": "noise", "field": "noise"}, "destination": {"node_id": "denoise", "field": "noise"}},
                    {"source": {"node_id": "denoise", "field": "latents"}, "destination": {"node_id": "latents_to_img", "field": "latents"}},
                    {"source": {"node_id": "vae_loader", "field": "vae"}, "destination": {"node_id": "latents_to_img", "field": "vae"}},
                ]
            }
            return await self._run_graph(client, graph)

    async def img2img(self, image_bytes: bytes, prompt: str, strength: float, params: dict) -> bytes:
        # Reuse inpaint with a full-white mask at the given strength
        from PIL import Image
        img = Image.open(BytesIO(image_bytes))
        mask = Image.new("L", img.size, 255)
        mask_buf = BytesIO()
        mask.save(mask_buf, format="PNG")
        p = dict(params)
        p.setdefault("denoising_start", 1.0 - strength)
        return await self.inpaint(image_bytes, mask_buf.getvalue(), prompt, p)

    async def outpaint(self, image_bytes: bytes, direction: str, size: int, prompt: str) -> bytes:
        # Delegate to inpaint with expanded canvas
        provider = OpenAIRemoteProvider.__new__(OpenAIRemoteProvider)
        return await provider.outpaint(image_bytes, direction, size, prompt)

    async def health(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                r = await client.get(f"{self.base_url}/api/v1/app/version")
                return r.status_code == 200
        except Exception:
            return False

    def capabilities(self) -> list[str]:
        return ["inpaint", "txt2img", "img2img", "outpaint"]


class ComfyUIProvider(RemoteAIProvider):
    """ComfyUI workflow JSON API driver."""

    def __init__(self, base_url: str, default_model: str = "v1-5-pruned-emaonly.ckpt"):
        self.base_url = base_url.rstrip("/")
        self.default_model = default_model

    async def _upload_image(self, client: httpx.AsyncClient, image_bytes: bytes, name: str = "image.png") -> str:
        files = {"image": (name, image_bytes, "image/png")}
        data = {"overwrite": "true"}
        r = await client.post(f"{self.base_url}/upload/image", files=files, data=data)
        r.raise_for_status()
        j = r.json()
        return j.get("name", name)

    async def _queue_prompt(self, client: httpx.AsyncClient, workflow: dict) -> str:
        r = await client.post(f"{self.base_url}/prompt", json={"prompt": workflow})
        r.raise_for_status()
        return r.json()["prompt_id"]

    async def _wait_for_result(self, client: httpx.AsyncClient, prompt_id: str) -> bytes:
        for _ in range(180):
            await asyncio.sleep(2)
            r = await client.get(f"{self.base_url}/history/{prompt_id}")
            r.raise_for_status()
            history = r.json()
            if prompt_id in history:
                outputs = history[prompt_id].get("outputs", {})
                for node_output in outputs.values():
                    for img_info in node_output.get("images", []):
                        img_r = await client.get(
                            f"{self.base_url}/view",
                            params={"filename": img_info["filename"], "subfolder": img_info.get("subfolder", ""),
                                    "type": img_info.get("type", "output")}
                        )
                        img_r.raise_for_status()
                        return img_r.content
        raise RuntimeError("ComfyUI timed out waiting for result")

    async def inpaint(self, image_bytes: bytes, mask_bytes: bytes, prompt: str, params: dict) -> bytes:
        model = params.get("model", self.default_model)
        async with httpx.AsyncClient(timeout=300.0) as client:
            img_name = await self._upload_image(client, image_bytes, "input.png")
            mask_name = await self._upload_image(client, mask_bytes, "mask.png")
            workflow = {
                "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": model}},
                "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
                "3": {"class_type": "CLIPTextEncode", "inputs": {"text": params.get("negative_prompt", ""), "clip": ["1", 1]}},
                "4": {"class_type": "LoadImage", "inputs": {"image": img_name}},
                "5": {"class_type": "LoadImage", "inputs": {"image": mask_name}},
                "6": {"class_type": "VAEEncode", "inputs": {"pixels": ["4", 0], "vae": ["1", 2]}},
                "7": {"class_type": "KSampler", "inputs": {
                    "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0],
                    "latent_image": ["6", 0], "mask": ["5", 0],
                    "seed": params.get("seed", 42), "steps": params.get("steps", 20),
                    "cfg": params.get("cfg_scale", 7.0), "sampler_name": "euler",
                    "scheduler": "normal", "denoise": params.get("denoise", 1.0)
                }},
                "8": {"class_type": "VAEDecode", "inputs": {"samples": ["7", 0], "vae": ["1", 2]}},
                "9": {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": "api_out"}},
            }
            pid = await self._queue_prompt(client, workflow)
            return await self._wait_for_result(client, pid)

    async def txt2img(self, prompt: str, width: int, height: int, params: dict) -> bytes:
        model = params.get("model", self.default_model)
        async with httpx.AsyncClient(timeout=300.0) as client:
            workflow = {
                "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": model}},
                "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
                "3": {"class_type": "CLIPTextEncode", "inputs": {"text": params.get("negative_prompt", ""), "clip": ["1", 1]}},
                "4": {"class_type": "EmptyLatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
                "5": {"class_type": "KSampler", "inputs": {
                    "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0],
                    "latent_image": ["4", 0],
                    "seed": params.get("seed", 42), "steps": params.get("steps", 20),
                    "cfg": params.get("cfg_scale", 7.0), "sampler_name": "euler",
                    "scheduler": "normal", "denoise": 1.0
                }},
                "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
                "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": "api_out"}},
            }
            pid = await self._queue_prompt(client, workflow)
            return await self._wait_for_result(client, pid)

    async def img2img(self, image_bytes: bytes, prompt: str, strength: float, params: dict) -> bytes:
        from PIL import Image
        img = Image.open(BytesIO(image_bytes))
        mask = Image.new("L", img.size, 255)
        mask_buf = BytesIO()
        mask.save(mask_buf, format="PNG")
        p = dict(params)
        p["denoise"] = strength
        return await self.inpaint(image_bytes, mask_buf.getvalue(), prompt, p)

    async def outpaint(self, image_bytes: bytes, direction: str, size: int, prompt: str) -> bytes:
        # Build expanded canvas then inpaint with blank mask
        from PIL import Image
        import numpy as np
        img = Image.open(BytesIO(image_bytes)).convert("RGB")
        w, h = img.size
        dw = size if direction in ("left", "right") else 0
        dh = size if direction in ("top", "bottom") else 0
        canvas = Image.new("RGB", (w + dw, h + dh), (128, 128, 128))
        ox = size if direction == "left" else 0
        oy = size if direction == "top" else 0
        canvas.paste(img, (ox, oy))
        mask_arr = np.zeros((h + dh, w + dw), dtype=np.uint8)
        if direction == "left":
            mask_arr[:, :size] = 255
        elif direction == "right":
            mask_arr[:, w:] = 255
        elif direction == "top":
            mask_arr[:size, :] = 255
        else:
            mask_arr[h:, :] = 255
        img_buf = BytesIO()
        canvas.save(img_buf, format="PNG")
        mask_buf = BytesIO()
        Image.fromarray(mask_arr, "L").save(mask_buf, format="PNG")
        return await self.inpaint(img_buf.getvalue(), mask_buf.getvalue(), prompt, {})

    async def health(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                r = await client.get(f"{self.base_url}/system_stats")
                return r.status_code == 200
        except Exception:
            return False

    def capabilities(self) -> list[str]:
        return ["inpaint", "txt2img", "img2img", "outpaint"]


def _build_provider(name: str) -> Optional[RemoteAIProvider]:
    """Instantiate a named provider from current settings."""
    from app.config import settings

    name = (name or "").lower().strip()

    if name == "openai":
        if not settings.openai_api_key:
            return None
        return OpenAIRemoteProvider(settings.openai_api_key, settings.openai_model)

    if name == "invokeai":
        if not settings.invokeai_url:
            return None
        return InvokeAIProvider(settings.invokeai_url, settings.invokeai_default_model)

    if name == "comfyui":
        if not settings.comfyui_url:
            return None
        return ComfyUIProvider(settings.comfyui_url, settings.comfyui_default_model)

    if name == "local_gpu":
        try:
            from app.services.local_diffusion import get_local_diffusion_provider
            return get_local_diffusion_provider(max_pipelines=settings.local_gpu_max_pipelines)
        except (ImportError, AttributeError) as exc:
            print(f"[local_gpu] Cannot load diffusion provider: {exc}")
            return None

    return None


# Map operation names to the settings field that holds the override
_OP_FIELD = {
    "inpaint":  "ai_provider_inpaint",
    "txt2img":  "ai_provider_txt2img",
    "img2img":  "ai_provider_img2img",
    "outpaint": "ai_provider_outpaint",
}


def get_remote_provider(operation: Optional[str] = None) -> Optional[RemoteAIProvider]:
    """
    Return the provider for a given operation.

    Resolution order:
      1. Per-operation override (AI_PROVIDER_INPAINT, AI_PROVIDER_TXT2IMG, etc.)
      2. Global default (AI_PROVIDER)
      3. None (local-only mode)

    Example .env for mixed setup:
      AI_PROVIDER=invokeai          # default for inpaint/img2img/outpaint
      AI_PROVIDER_TXT2IMG=openai    # use OpenAI only for text-to-image
    """
    from app.config import settings

    if operation and operation in _OP_FIELD:
        override = getattr(settings, _OP_FIELD[operation], "")
        if override:
            provider = _build_provider(override)
            if provider is not None:
                return provider
            # override configured but not usable (missing key/url) — fall through to default

    return _build_provider(settings.ai_provider)

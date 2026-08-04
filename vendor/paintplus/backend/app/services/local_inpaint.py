"""
Local inpainting operations — LaMa, OpenCV, and background removal.
All operations use GPU automatically if PyTorch detects one, CPU otherwise.
"""

from io import BytesIO
from PIL import Image
import numpy as np
import cv2

# Lazy-loaded LaMa model (downloaded on first use, ~100MB)
_lama = None


def get_lama():
    global _lama
    if _lama is None:
        from simple_lama_inpainting import SimpleLama
        _lama = SimpleLama()
    return _lama


def lama_available() -> bool:
    try:
        import simple_lama_inpainting  # noqa: F401
        return True
    except ImportError:
        return False


def lama_inpaint(image_bytes: bytes, mask_bytes: bytes) -> bytes:
    """LaMa structural inpainting — best for object removal and large fills."""
    lama = get_lama()
    image = Image.open(BytesIO(image_bytes)).convert("RGB")
    mask = Image.open(BytesIO(mask_bytes)).convert("L")
    if mask.size != image.size:
        mask = mask.resize(image.size, Image.Resampling.LANCZOS)
    result = lama(image, mask)
    buf = BytesIO()
    result.save(buf, format="PNG")
    return buf.getvalue()


def opencv_inpaint(image_bytes: bytes, mask_bytes: bytes, method: str = "telea") -> bytes:
    """OpenCV fast structural inpainting — CPU only, milliseconds."""
    image = Image.open(BytesIO(image_bytes)).convert("RGB")
    mask = Image.open(BytesIO(mask_bytes)).convert("L")
    if mask.size != image.size:
        mask = mask.resize(image.size, Image.Resampling.LANCZOS)

    img_np = np.array(image)
    mask_np = np.array(mask)
    _, mask_bin = cv2.threshold(mask_np, 127, 255, cv2.THRESH_BINARY)

    flags = cv2.INPAINT_TELEA if method == "telea" else cv2.INPAINT_NS
    result = cv2.inpaint(img_np, mask_bin, inpaintRadius=3, flags=flags)

    buf = BytesIO()
    Image.fromarray(result).save(buf, format="PNG")
    return buf.getvalue()


def remove_background_rembg(image_bytes: bytes) -> bytes:
    """Background removal using rembg."""
    from rembg import remove
    return remove(image_bytes)


def rembg_available() -> bool:
    try:
        import rembg  # noqa: F401
        return True
    except ImportError:
        return False


def gpu_available() -> bool:
    try:
        import torch
        return torch.cuda.is_available()
    except ImportError:
        return False

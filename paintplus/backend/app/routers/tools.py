from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from fastapi.responses import Response
from sqlalchemy.orm import Session
from typing import Optional
from PIL import Image
from io import BytesIO
import numpy as np
import json
import base64
import cv2
from pydantic import BaseModel

from app.database import get_db
from app.models.project import Project
from app.schemas import StatusResponse

router = APIRouter(prefix="/tools", tags=["tools"])


# Pydantic models for JSON API
class SmartSelectRequest(BaseModel):
    image: str  # Base64 encoded image
    point_x: int
    point_y: int


class InpaintRequest(BaseModel):
    image: str  # Base64 encoded image
    mask: str  # Base64 encoded mask
    prompt: str
    negative_prompt: Optional[str] = ""
    strength: Optional[float] = 0.8
    guidance_scale: Optional[float] = 7.5


class RemoveBackgroundRequest(BaseModel):
    image: str  # Base64 encoded image
    model: Optional[str] = "auto"  # "auto", "ben2", "birefnet-hr", "u2net", "rembg"


@router.post("/smart-select-base64")
async def smart_select_base64(request: SmartSelectRequest):
    """
    Smart select using base64 encoded image (no project required).
    Used by miniPaint frontend.
    """
    try:
        # Decode base64 image
        image_bytes = base64.b64decode(request.image)
        img = Image.open(BytesIO(image_bytes)).convert('RGB')
        img_array = np.array(img)

        # Run SAM selection
        try:
            mask = await _sam_select(img_array, request.point_x, request.point_y)
        except Exception as e:
            print(f"SAM not available, using flood fill: {e}")
            mask = _flood_fill_select(img_array, request.point_x, request.point_y)

        # Convert mask to base64 PNG
        mask_img = Image.fromarray((mask * 255).astype(np.uint8), mode='L')
        buffer = BytesIO()
        mask_img.save(buffer, format='PNG')
        mask_b64 = base64.b64encode(buffer.getvalue()).decode('utf-8')

        # Get polygon and bbox
        polygon, bbox = _mask_to_polygon(mask)

        return {
            "mask": mask_b64,
            "polygon": polygon,
            "bbox": bbox
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/inpaint")
async def inpaint_base64(request: InpaintRequest):
    """
    AI inpainting using base64 encoded image and mask.
    Used by miniPaint frontend.
    """
    try:
        # Decode base64 image and mask
        image_bytes = base64.b64decode(request.image)
        mask_bytes = base64.b64decode(request.mask)

        img = Image.open(BytesIO(image_bytes)).convert('RGB')
        mask_img = Image.open(BytesIO(mask_bytes)).convert('L')

        # Resize mask to match image if needed
        if mask_img.size != img.size:
            mask_img = mask_img.resize(img.size, Image.Resampling.LANCZOS)

        # Get the AI provider
        from app.services.ai_provider import get_ai_provider

        provider = get_ai_provider()

        # Convert images to bytes for provider
        img_buffer = BytesIO()
        img.save(img_buffer, format='PNG')
        img_bytes = img_buffer.getvalue()

        mask_buffer = BytesIO()
        mask_img.save(mask_buffer, format='PNG')
        mask_bytes_png = mask_buffer.getvalue()

        # Run inpainting using edit_image method
        result_bytes = await provider.edit_image(
            patch_image_bytes=img_bytes,
            mask_image_bytes=mask_bytes_png,
            prompt=request.prompt,
            mode="A"  # Patch-only mode
        )

        # Convert result to base64
        result_b64 = base64.b64encode(result_bytes).decode('utf-8')

        return {
            "result": result_b64
        }

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/remove-background-base64")
async def remove_background_base64(request: RemoveBackgroundRequest):
    """
    Remove background from a base64 encoded image.

    request.model selects the backend:
      - "auto" (default): BG_REMOVAL_MODEL setting first, then falls back
        through the other local models, then rembg as a last resort.
      - "ben2" / "birefnet-hr" / "u2net": use only that local model.
      - "rembg": skip local models, use rembg directly.

    Returns base64 encoded PNG with transparent background.
    Used by miniPaint frontend.
    """
    try:
        from app.config import settings

        # Decode base64 image
        image_bytes = base64.b64decode(request.image)
        img = Image.open(BytesIO(image_bytes)).convert('RGB')

        local_backends = {
            "ben2": _remove_background_ben2,
            "birefnet-hr": _remove_background_birefnet_hr,
            "u2net": _remove_background_u2net,
        }

        if request.model in local_backends:
            order = [request.model]
        elif request.model == "rembg":
            order = []
        else:
            preferred = settings.bg_removal_model if settings.bg_removal_model in local_backends else "ben2"
            order = [preferred] + [name for name in ("ben2", "u2net") if name != preferred]

        result_bytes = None
        method_used = None

        for name in order:
            try:
                result_bytes = await local_backends[name](img)
                method_used = name
                break
            except Exception as e:
                print(f"{name} failed: {e}")

        # rembg is the universal last resort (also reachable directly via model="rembg")
        if result_bytes is None and request.model in ("auto", "rembg"):
            try:
                from rembg import remove, new_session
                try:
                    session = new_session("birefnet-general")
                    result_bytes = remove(image_bytes, session=session)
                    method_used = "birefnet"
                except Exception:
                    result_bytes = remove(image_bytes)
                    method_used = "rembg-default"
            except ImportError:
                pass
            except Exception as e:
                print(f"rembg failed: {e}")

        if result_bytes is None:
            raise HTTPException(
                status_code=500,
                detail="No background removal method available. Install ben2, u2net, or rembg."
            )

        # Convert result to base64
        result_b64 = base64.b64encode(result_bytes).decode('utf-8')

        # Get dimensions
        result_img = Image.open(BytesIO(result_bytes))

        return {
            "result": result_b64,
            "width": result_img.width,
            "height": result_img.height,
            "method": method_used
        }

    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


# Global U2Net model cache
_u2net_model = None


async def _download_u2net_model(models_dir):
    """Auto-download U2Net PyTorch model (~176MB) for background removal"""
    import urllib.request
    from pathlib import Path

    models_dir = Path(models_dir)
    models_dir.mkdir(parents=True, exist_ok=True)

    # Download U2Net PyTorch model (avoids ONNX executable stack issues in Docker)
    # Using the PyTorch state dict format
    url = "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net.onnx"
    dest_path = models_dir / "u2net.onnx"

    print(f"Downloading U2Net model from {url} (~176MB)...")
    print("This may take a few minutes...")

    def download_progress(count, block_size, total_size):
        if total_size > 0:
            percent = min(100, count * block_size * 100 // total_size)
            downloaded_mb = (count * block_size) / (1024 * 1024)
            total_mb = total_size / (1024 * 1024)
            if count % 500 == 0:
                print(f"  Download progress: {percent}% ({downloaded_mb:.1f}/{total_mb:.1f} MB)")

    urllib.request.urlretrieve(url, str(dest_path), download_progress)
    print(f"U2Net model downloaded to {dest_path}")

    return dest_path


async def _remove_background_u2net(img: Image.Image) -> bytes:
    """
    Remove background using U2Net model via OpenCV DNN.
    Uses OpenCV's DNN module which doesn't have executable stack issues.
    """
    global _u2net_model

    from pathlib import Path

    # Check for U2Net model
    models_dir = Path('/app/data/models')
    u2net_path = None

    # Check for ONNX model (preferred for OpenCV DNN)
    for alt_name in ['u2net.onnx', 'u2netp.onnx']:
        alt_path = models_dir / alt_name
        if alt_path.exists():
            u2net_path = alt_path
            break

    if u2net_path is None:
        # Try to auto-download the model
        print("U2Net model not found, attempting to download...")
        try:
            await _download_u2net_model(models_dir)
            # Check again
            for alt_name in ['u2net.onnx', 'u2netp.onnx']:
                alt_path = models_dir / alt_name
                if alt_path.exists():
                    u2net_path = alt_path
                    break
        except Exception as download_error:
            print(f"Auto-download failed: {download_error}")

    if u2net_path is None:
        raise FileNotFoundError(
            "U2Net model not found. To fix this, run:\n"
            "  docker exec -it ai-photo-edit-backend python /scripts/download_u2net_model.py\n"
            "Or manually download from: https://github.com/danielgatis/rembg/releases"
        )

    # Load model if not cached (using OpenCV DNN - no executable stack issues)
    if _u2net_model is None:
        print(f"Loading U2Net model from {u2net_path} using OpenCV DNN")
        try:
            _u2net_model = cv2.dnn.readNetFromONNX(str(u2net_path))
            print("U2Net model loaded successfully with OpenCV DNN")
        except Exception as e:
            print(f"Failed to load with OpenCV DNN: {e}")
            raise

    # Preprocess image
    original_size = img.size
    input_size = 320

    # Resize and convert to blob
    img_resized = img.resize((input_size, input_size), Image.Resampling.BILINEAR)
    img_np = np.array(img_resized).astype(np.float32)

    # Normalize (ImageNet normalization)
    img_np = img_np / 255.0
    img_np = (img_np - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]

    # Create blob (NCHW format)
    blob = cv2.dnn.blobFromImage(
        img_np.astype(np.float32),
        scalefactor=1.0,
        size=(input_size, input_size),
        swapRB=False
    )

    # Run inference
    _u2net_model.setInput(blob)
    outputs = _u2net_model.forward()

    # Get mask from first output
    mask = outputs[0, 0]

    # Post-process mask
    mask = (mask - mask.min()) / (mask.max() - mask.min() + 1e-8)
    mask = (mask * 255).astype(np.uint8)

    # Resize mask back to original size
    mask_img = Image.fromarray(mask).resize(original_size, Image.Resampling.BILINEAR)

    # Apply mask to original image
    result = img.convert('RGBA')
    result.putalpha(mask_img)

    # Save to bytes
    buffer = BytesIO()
    result.save(buffer, format='PNG')
    return buffer.getvalue()


# Global BEN2 model cache
_ben2_model = None


async def _remove_background_ben2(img: Image.Image) -> bytes:
    """
    Remove background using BEN2 (Confidence Guided Matting) — clean cutouts,
    strong on hair/fur edges. MIT licensed. Downloads weights from HF Hub on
    first use (cached under the hf_cache bind mount).
    """
    global _ben2_model

    if _ben2_model is None:
        import torch
        from ben2 import AutoModel as Ben2AutoModel

        device = 'cuda' if torch.cuda.is_available() else 'cpu'
        print(f"Loading BEN2_Base model on {device} (first run downloads ~170MB from HuggingFace)")
        _ben2_model = Ben2AutoModel.from_pretrained("PramaLLC/BEN2")
        _ben2_model.to(device).eval()
        print("BEN2_Base model loaded")

    # refine_foreground=True runs BEN2's extra foreground-color refinement pass
    # (slower, but recovers fine/semi-transparent edge detail instead of a hard
    # cutout — matters for things like lace, light rays, or fine text borders).
    result = _ben2_model.inference(img.convert('RGB'), refine_foreground=True)

    buffer = BytesIO()
    result.save(buffer, format='PNG')
    return buffer.getvalue()


# Global BiRefNet-HR model cache
_birefnet_hr_model = None
_birefnet_hr_device = None


async def _remove_background_birefnet_hr(img: Image.Image) -> bytes:
    """
    Remove background using BiRefNet-HR (2048x2048, MIT licensed) — best for
    high-resolution / print work. Downloads weights from HF Hub on first use.
    """
    global _birefnet_hr_model, _birefnet_hr_device

    import torch
    from torchvision import transforms

    if _birefnet_hr_model is None:
        from transformers import AutoModelForImageSegmentation

        _birefnet_hr_device = 'cuda' if torch.cuda.is_available() else 'cpu'
        print(f"Loading BiRefNet-HR model on {_birefnet_hr_device} (first run downloads ~900MB from HuggingFace)")
        _birefnet_hr_model = AutoModelForImageSegmentation.from_pretrained(
            'zhengpeng7/BiRefNet_HR', trust_remote_code=True
        )
        _birefnet_hr_model.to(_birefnet_hr_device).eval()
        print("BiRefNet-HR model loaded")

    original_size = img.size
    rgb_img = img.convert('RGB')

    transform = transforms.Compose([
        transforms.Resize((2048, 2048)),
        transforms.ToTensor(),
        transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
    ])
    input_tensor = transform(rgb_img).unsqueeze(0).to(_birefnet_hr_device)

    with torch.no_grad():
        preds = _birefnet_hr_model(input_tensor)[-1].sigmoid().cpu()

    mask = transforms.ToPILImage()(preds[0].squeeze()).resize(original_size, Image.Resampling.LANCZOS)

    result = rgb_img.convert('RGBA')
    result.putalpha(mask)

    buffer = BytesIO()
    result.save(buffer, format='PNG')
    return buffer.getvalue()


@router.post("/remove-background")
async def remove_background(
    project_id: Optional[int] = Form(None),
    file: Optional[UploadFile] = File(None),
    db: Session = Depends(get_db)
):
    """
    Remove background from an image using rembg with BiRefNet model.

    Either provide project_id to use current project image,
    or upload a file directly.

    Returns PNG with transparent background.
    """
    try:
        from rembg import remove, new_session
    except ImportError:
        raise HTTPException(
            status_code=500,
            detail="rembg not installed. Run: pip install rembg"
        )

    # Get image bytes
    if file:
        image_bytes = await file.read()
    elif project_id:
        project = db.query(Project).filter(Project.id == project_id).first()
        if not project:
            raise HTTPException(status_code=404, detail="Project not found")

        from app.services.edit_service import EditService
        edit_service = EditService()
        image_path = edit_service.get_current_image_path(project_id)

        with open(image_path, 'rb') as f:
            image_bytes = f.read()
    else:
        raise HTTPException(
            status_code=400,
            detail="Provide either project_id or file"
        )

    # Remove background using BiRefNet (state-of-the-art)
    try:
        session = new_session("birefnet-general")
        result_bytes = remove(image_bytes, session=session)
    except Exception:
        result_bytes = remove(image_bytes)

    return Response(
        content=result_bytes,
        media_type="image/png",
        headers={"Content-Disposition": "inline; filename=no-background.png"}
    )


@router.post("/remove-background-to-layer")
async def remove_background_to_layer(
    project_id: int = Form(...),
    db: Session = Depends(get_db)
):
    """
    Remove background using BiRefNet and save as a new layer in the project.
    Returns layer info that can be added to frontend layer system.
    """
    try:
        from rembg import remove, new_session
    except ImportError:
        raise HTTPException(
            status_code=500,
            detail="rembg not installed. Run: pip install rembg"
        )

    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    from app.services.edit_service import EditService
    from pathlib import Path

    edit_service = EditService()
    image_path = edit_service.get_current_image_path(project_id)

    with open(image_path, 'rb') as f:
        image_bytes = f.read()

    # Remove background using BiRefNet (state-of-the-art)
    try:
        session = new_session("birefnet-general")
        result_bytes = remove(image_bytes, session=session)
    except Exception:
        result_bytes = remove(image_bytes)

    # Save as layer file
    project_dir = edit_service.get_project_dir(project_id)
    layers_dir = project_dir / 'layers'
    layers_dir.mkdir(exist_ok=True)

    # Find next layer number
    existing_layers = list(layers_dir.glob('layer_*.png'))
    layer_num = len(existing_layers) + 1
    layer_path = layers_dir / f'layer_{layer_num}.png'

    with open(layer_path, 'wb') as f:
        f.write(result_bytes)

    # Get dimensions
    img = Image.open(BytesIO(result_bytes))

    return {
        "status": "success",
        "layer": {
            "id": layer_num,
            "name": f"No Background {layer_num}",
            "path": str(layer_path),
            "width": img.width,
            "height": img.height,
            "type": "background_removed"
        }
    }


@router.post("/smart-select")
async def smart_select(
    project_id: int = Form(...),
    point_x: int = Form(...),
    point_y: int = Form(...),
    return_format: str = Form("json"),  # "json" (default) or "image"
    db: Session = Depends(get_db)
):
    """
    Use SAM (Segment Anything) to select object at given point.
    Returns mask and polygon data for the selected object.

    Note: Requires SAM model to be downloaded.
    Falls back to simple flood-fill selection if SAM unavailable.
    """
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    from app.services.edit_service import EditService
    edit_service = EditService()
    image_path = edit_service.get_current_image_path(project_id)

    img = Image.open(image_path).convert('RGB')
    img_array = np.array(img)

    # Try SAM first, fall back to flood fill
    try:
        mask = await _sam_select(img_array, point_x, point_y)
    except Exception as e:
        print(f"SAM not available, using flood fill: {e}")
        mask = _flood_fill_select(img_array, point_x, point_y)

    # Convert mask to PNG
    mask_img = Image.fromarray((mask * 255).astype(np.uint8), mode='L')

    if return_format == "image":
        buffer = BytesIO()
        mask_img.save(buffer, format='PNG')
        return Response(
            content=buffer.getvalue(),
            media_type="image/png"
        )

    # Return JSON with polygon and bbox
    polygon, bbox = _mask_to_polygon(mask)

    # Also return mask as base64 for potential use
    buffer = BytesIO()
    mask_img.save(buffer, format='PNG')
    mask_b64 = base64.b64encode(buffer.getvalue()).decode('utf-8')

    return {
        "polygon": polygon,
        "bbox": bbox,
        "mask_base64": mask_b64,
    }


def _mask_to_polygon(mask: np.ndarray) -> tuple:
    """
    Convert a binary mask to a simplified polygon and bounding box.

    Returns:
        (polygon, bbox) where:
        - polygon: list of [x, y] points (simplified contour)
        - bbox: dict with x, y, width, height
    """
    # Ensure mask is binary uint8
    mask_uint8 = (mask * 255).astype(np.uint8) if mask.max() <= 1 else mask.astype(np.uint8)

    # Find contours
    contours, _ = cv2.findContours(mask_uint8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    if not contours:
        return [], {"x": 0, "y": 0, "width": 0, "height": 0}

    # Get largest contour
    largest = max(contours, key=cv2.contourArea)

    # Get bounding box
    x, y, w, h = cv2.boundingRect(largest)
    bbox = {"x": int(x), "y": int(y), "width": int(w), "height": int(h)}

    # Simplify contour to reduce points (epsilon = 1% of arc length)
    epsilon = 0.01 * cv2.arcLength(largest, True)
    simplified = cv2.approxPolyDP(largest, epsilon, True)

    # Convert to list of [x, y] points
    polygon = [[int(pt[0][0]), int(pt[0][1])] for pt in simplified]

    return polygon, bbox


# Global SAM model cache (loaded once, reused)
_sam_model = None
_sam_predictor = None


def _get_sam_model():
    """Load SAM model from local file (cached after first load)"""
    global _sam_model, _sam_predictor

    if _sam_predictor is not None:
        return _sam_predictor

    from pathlib import Path

    # Check for SAM model in models directory
    models_dir = Path('/app/data/models')
    model_path = models_dir / 'sam_model.pth'

    # Also check for specific model files
    if not model_path.exists():
        for filename in ['sam_vit_b_01ec64.pth', 'sam_vit_l_0b3195.pth', 'sam_vit_h_4b8939.pth']:
            alt_path = models_dir / filename
            if alt_path.exists():
                model_path = alt_path
                break

    if not model_path.exists():
        raise FileNotFoundError(
            f"SAM model not found. Download it with:\n"
            f"  docker exec -it ai-photo-edit-backend python /scripts/download_sam_model.py"
        )

    # Determine model type from filename
    model_type = 'vit_b'  # default
    if 'vit_l' in model_path.name:
        model_type = 'vit_l'
    elif 'vit_h' in model_path.name:
        model_type = 'vit_h'

    print(f"Loading SAM model: {model_path} (type: {model_type})")

    import torch
    from segment_anything import sam_model_registry, SamPredictor

    # Use CPU by default (works everywhere), GPU if available
    device = 'cuda' if torch.cuda.is_available() else 'cpu'

    _sam_model = sam_model_registry[model_type](checkpoint=str(model_path))
    _sam_model.to(device)
    _sam_predictor = SamPredictor(_sam_model)

    print(f"SAM model loaded on {device}")
    return _sam_predictor


def _sam_select_local(img_array: np.ndarray, x: int, y: int) -> np.ndarray:
    """Use local SAM model for selection (no API calls, runs offline)"""
    predictor = _get_sam_model()

    # Set image
    predictor.set_image(img_array)

    # Point coordinates (x, y) and label (1 = foreground)
    input_point = np.array([[x, y]])
    input_label = np.array([1])

    # Get mask prediction
    masks, scores, _ = predictor.predict(
        point_coords=input_point,
        point_labels=input_label,
        multimask_output=True,  # Get multiple mask options
    )

    # Use the mask with highest score
    best_mask_idx = np.argmax(scores)
    mask = masks[best_mask_idx]

    return mask.astype(np.uint8)


async def _sam_select(img_array: np.ndarray, x: int, y: int) -> np.ndarray:
    """
    Smart object selection using SAM (Segment Anything Model).

    Priority:
    1. Local SAM model (free, fast, offline)
    2. Replicate API (if local not available and API key set)
    3. Raises exception if neither available
    """
    # Try local SAM first (free, no API calls)
    try:
        return _sam_select_local(img_array, x, y)
    except FileNotFoundError as e:
        print(f"Local SAM not available: {e}")
    except ImportError as e:
        print(f"SAM dependencies not installed: {e}")
    except Exception as e:
        print(f"Local SAM failed: {e}")

    # Fall back to Replicate API
    from app.config import settings

    if not settings.replicate_api_key:
        raise ValueError(
            "SAM model not available. Either:\n"
            "  1. Download local model: docker exec -it ai-photo-edit-backend python /scripts/download_sam_model.py\n"
            "  2. Or set REPLICATE_API_KEY in .env for cloud SAM"
        )

    return await _sam_select_replicate(img_array, x, y)


async def _sam_select_replicate(img_array: np.ndarray, x: int, y: int) -> np.ndarray:
    """Fallback: Use SAM via Replicate API (requires API key, costs ~$0.002/call)"""
    import httpx
    import base64
    import asyncio
    from app.config import settings

    # Convert image to base64
    img = Image.fromarray(img_array)
    buffer = BytesIO()
    img.save(buffer, format='PNG')
    img_b64 = base64.b64encode(buffer.getvalue()).decode('utf-8')

    async with httpx.AsyncClient(timeout=120.0) as client:
        prediction_data = {
            "version": "meta/sam-2-image:fe97b453d6525baeeb530595c74a3c4f567c1f655ee2a0fee11f76bd1d31e495",
            "input": {
                "image": f"data:image/png;base64,{img_b64}",
                "point_coords": f"{x},{y}",
                "point_labels": "1",
            }
        }

        headers = {
            'Authorization': f'Bearer {settings.replicate_api_key}',
            'Content-Type': 'application/json'
        }

        response = await client.post(
            "https://api.replicate.com/v1/predictions",
            json=prediction_data,
            headers=headers
        )

        if response.status_code != 201:
            raise Exception(f"Replicate API error: {response.text}")

        prediction = response.json()
        prediction_url = prediction['urls']['get']

        # Poll for completion
        for _ in range(60):
            await asyncio.sleep(2)
            status_response = await client.get(prediction_url, headers=headers)
            status_data = status_response.json()

            if status_data['status'] == 'succeeded':
                mask_url = status_data['output']
                if isinstance(mask_url, list):
                    mask_url = mask_url[0]

                mask_response = await client.get(mask_url)
                mask_img = Image.open(BytesIO(mask_response.content)).convert('L')

                if mask_img.size != (img_array.shape[1], img_array.shape[0]):
                    mask_img = mask_img.resize(
                        (img_array.shape[1], img_array.shape[0]),
                        Image.Resampling.LANCZOS
                    )

                return np.array(mask_img) // 255

            elif status_data['status'] == 'failed':
                raise Exception(f"SAM prediction failed: {status_data.get('error')}")

        raise Exception("SAM prediction timed out")


def _flood_fill_select(img_array: np.ndarray, x: int, y: int, tolerance: int = 32) -> np.ndarray:
    """Simple flood-fill based selection with color tolerance"""
    import cv2

    h, w = img_array.shape[:2]

    # Ensure point is within bounds
    x = max(0, min(x, w - 1))
    y = max(0, min(y, h - 1))

    # Create mask for flood fill (needs to be 2 pixels larger)
    mask = np.zeros((h + 2, w + 2), np.uint8)

    # Flood fill
    cv2.floodFill(
        img_array.copy(),
        mask,
        (x, y),
        (255, 255, 255),
        (tolerance, tolerance, tolerance),
        (tolerance, tolerance, tolerance),
        cv2.FLOODFILL_MASK_ONLY
    )

    # Extract the actual mask (remove padding)
    return mask[1:-1, 1:-1]


@router.post("/color-select")
async def color_select(
    project_id: int = Form(...),
    color_r: int = Form(...),
    color_g: int = Form(...),
    color_b: int = Form(...),
    tolerance: int = Form(30),
    return_format: str = Form("json"),  # "json" (default) or "image"
    db: Session = Depends(get_db)
):
    """
    Select all pixels similar to the given color.
    Returns a mask and polygon data for selected areas.
    """
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    from app.services.edit_service import EditService
    edit_service = EditService()
    image_path = edit_service.get_current_image_path(project_id)

    img = Image.open(image_path).convert('RGB')
    img_array = np.array(img)

    # Target color
    target = np.array([color_r, color_g, color_b])

    # Calculate color distance
    diff = np.abs(img_array.astype(np.int16) - target.astype(np.int16))
    distance = np.sum(diff, axis=2)

    # Create mask where distance is within tolerance
    mask = (distance <= tolerance * 3).astype(np.uint8)

    # Convert to PNG
    mask_img = Image.fromarray(mask * 255, mode='L')

    if return_format == "image":
        buffer = BytesIO()
        mask_img.save(buffer, format='PNG')
        return Response(
            content=buffer.getvalue(),
            media_type="image/png"
        )

    # Return JSON with polygon and bbox
    polygon, bbox = _mask_to_polygon(mask)

    buffer = BytesIO()
    mask_img.save(buffer, format='PNG')
    mask_b64 = base64.b64encode(buffer.getvalue()).decode('utf-8')

    return {
        "polygon": polygon,
        "bbox": bbox,
        "mask_base64": mask_b64,
        "color": {"r": color_r, "g": color_g, "b": color_b},
        "tolerance": tolerance,
    }


@router.post("/extract-object")
async def extract_object(
    project_id: int = Form(...),
    mask: UploadFile = File(...),
    db: Session = Depends(get_db)
):
    """
    Extract object using provided mask.
    Returns PNG with transparent background containing only the masked area.
    """
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    from app.services.edit_service import EditService
    edit_service = EditService()
    image_path = edit_service.get_current_image_path(project_id)

    # Load image and mask
    img = Image.open(image_path).convert('RGBA')
    mask_bytes = await mask.read()
    mask_img = Image.open(BytesIO(mask_bytes)).convert('L')

    # Resize mask if needed
    if mask_img.size != img.size:
        mask_img = mask_img.resize(img.size, Image.Resampling.LANCZOS)

    # Apply mask as alpha channel
    img_array = np.array(img)
    mask_array = np.array(mask_img)

    # Set alpha channel based on mask
    img_array[:, :, 3] = mask_array

    result = Image.fromarray(img_array, mode='RGBA')

    buffer = BytesIO()
    result.save(buffer, format='PNG')

    return Response(
        content=buffer.getvalue(),
        media_type="image/png"
    )


@router.get("/layers/{project_id}")
async def list_layers(
    project_id: int,
    db: Session = Depends(get_db)
):
    """List all layers for a project"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    from app.services.edit_service import EditService
    from pathlib import Path

    edit_service = EditService()
    project_dir = edit_service.get_project_dir(project_id)
    layers_dir = project_dir / 'layers'

    if not layers_dir.exists():
        return {"layers": []}

    layers = []
    for layer_file in sorted(layers_dir.glob('layer_*.png')):
        img = Image.open(layer_file)
        layer_num = int(layer_file.stem.split('_')[1])
        layers.append({
            "id": layer_num,
            "name": f"Layer {layer_num}",
            "path": str(layer_file),
            "width": img.width,
            "height": img.height
        })

    return {"layers": layers}


@router.post("/flatten-layers")
async def flatten_layers(
    project_id: int = Form(...),
    layer_order: str = Form(...),  # JSON array of layer IDs in order
    db: Session = Depends(get_db)
):
    """
    Flatten all layers into a single image and save as current.
    layer_order is a JSON array like [1, 2, 3] from bottom to top.
    """
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    from app.services.edit_service import EditService
    from pathlib import Path

    edit_service = EditService()
    project_dir = edit_service.get_project_dir(project_id)
    layers_dir = project_dir / 'layers'

    order = json.loads(layer_order)

    # Start with original image as base
    base_path = edit_service.get_current_image_path(project_id)
    result = Image.open(base_path).convert('RGBA')

    # Composite layers in order
    for layer_id in order:
        layer_path = layers_dir / f'layer_{layer_id}.png'
        if layer_path.exists():
            layer = Image.open(layer_path).convert('RGBA')
            # Resize if needed
            if layer.size != result.size:
                layer = layer.resize(result.size, Image.Resampling.LANCZOS)
            result = Image.alpha_composite(result, layer)

    # Save as current
    result.save(base_path, 'PNG')

    return StatusResponse(
        status="success",
        message="Layers flattened successfully"
    )

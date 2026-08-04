from PIL import Image, ImageFilter, ImageDraw
import numpy as np
from io import BytesIO
from typing import Tuple, Dict
import cv2


def bytes_to_image(image_bytes: bytes) -> Image.Image:
    """Convert bytes to PIL Image"""
    return Image.open(BytesIO(image_bytes)).convert('RGBA')


def image_to_bytes(image: Image.Image, format: str = 'PNG') -> bytes:
    """Convert PIL Image to bytes"""
    buffer = BytesIO()
    image.save(buffer, format=format)
    return buffer.getvalue()


def crop_patch(image: Image.Image, bbox: Dict[str, int]) -> Image.Image:
    """
    Crop a patch from the image using bounding box

    Args:
        image: PIL Image
        bbox: Dictionary with x, y, width, height

    Returns:
        Cropped patch as PIL Image
    """
    x, y, width, height = bbox['x'], bbox['y'], bbox['width'], bbox['height']
    return image.crop((x, y, x + width, y + height))


def create_feathered_mask(mask: Image.Image, feather_px: int) -> Image.Image:
    """
    Apply feathering (Gaussian blur) to mask edges

    Args:
        mask: Binary mask image (grayscale)
        feather_px: Feather radius in pixels

    Returns:
        Feathered mask
    """
    if feather_px <= 0:
        return mask

    # Apply Gaussian blur for feathering
    feathered = mask.filter(ImageFilter.GaussianBlur(radius=feather_px))
    return feathered


def blend_patch(
    original_patch: Image.Image,
    regenerated_patch: Image.Image,
    mask: Image.Image,
    feather_px: int = 0,
    preserve_alpha: bool = True
) -> Image.Image:
    """
    Blend regenerated patch with original using mask.
    Preserves original alpha channel for semi-transparent areas (veils, glass, etc).

    Args:
        original_patch: Original cropped patch
        regenerated_patch: AI-regenerated patch
        mask: Binary mask (same size as patches)
        feather_px: Feather radius for smooth blending
        preserve_alpha: If True, preserves original alpha channel

    Returns:
        Blended patch with preserved transparency
    """
    # Ensure all images are the same size
    if regenerated_patch.size != original_patch.size:
        regenerated_patch = regenerated_patch.resize(original_patch.size, Image.Resampling.LANCZOS)

    if mask.size != original_patch.size:
        mask = mask.resize(original_patch.size, Image.Resampling.LANCZOS)

    # Convert mask to grayscale if needed
    if mask.mode != 'L':
        mask = mask.convert('L')

    # Apply feathering to mask
    feathered_mask = create_feathered_mask(mask, feather_px)

    # Convert images to RGBA, storing original alpha
    original_rgba = original_patch.convert('RGBA')
    original_alpha = original_rgba.split()[3]  # Store original alpha channel

    regenerated_rgba = regenerated_patch.convert('RGBA')

    # Blend using the feathered mask
    blended = Image.composite(regenerated_rgba, original_rgba, feathered_mask)

    # Restore original alpha channel to preserve transparency
    # This keeps semi-transparent areas (veils, glass, smoke) intact
    if preserve_alpha:
        r, g, b, _ = blended.split()
        blended = Image.merge('RGBA', (r, g, b, original_alpha))

    return blended


def insert_patch(
    full_image: Image.Image,
    patch: Image.Image,
    bbox: Dict[str, int]
) -> Image.Image:
    """
    Insert a patch back into the full image at the specified bbox

    Args:
        full_image: Full original image
        patch: Patch to insert
        bbox: Bounding box {x, y, width, height}

    Returns:
        Full image with patch inserted
    """
    result = full_image.copy()
    x, y = bbox['x'], bbox['y']

    # Ensure patch is the correct size
    if patch.size != (bbox['width'], bbox['height']):
        patch = patch.resize((bbox['width'], bbox['height']), Image.Resampling.LANCZOS)

    # Paste the patch
    result.paste(patch, (x, y), patch if patch.mode == 'RGBA' else None)

    return result


def create_mask_from_selection(
    width: int,
    height: int,
    selection_type: str,
    selection_data: Dict
) -> Image.Image:
    """
    Create a binary mask from selection data

    Args:
        width: Mask width
        height: Mask height
        selection_type: "rectangle", "ellipse", or "lasso"
        selection_data: Selection-specific data

    Returns:
        Binary mask (white = selected, black = not selected)
    """
    mask = Image.new('L', (width, height), 0)
    draw = ImageDraw.Draw(mask)

    if selection_type == "rectangle":
        # Fill entire rectangle
        draw.rectangle([0, 0, width, height], fill=255)

    elif selection_type == "ellipse":
        # Fill entire ellipse
        draw.ellipse([0, 0, width, height], fill=255)

    elif selection_type == "lasso":
        # Draw polygon from points
        points = selection_data.get('points', [])
        if points:
            # Convert points to relative coordinates within bbox
            draw.polygon(points, fill=255)

    return mask


def ensure_even_dimensions(image: Image.Image) -> Image.Image:
    """
    Ensure image dimensions are even numbers (required by some AI providers)

    Args:
        image: PIL Image

    Returns:
        Image with even dimensions
    """
    width, height = image.size
    new_width = width if width % 2 == 0 else width + 1
    new_height = height if height % 2 == 0 else height + 1

    if (new_width, new_height) != (width, height):
        new_image = Image.new(image.mode, (new_width, new_height), (0, 0, 0, 0))
        new_image.paste(image, (0, 0))
        return new_image

    return image


def resize_for_ai(image: Image.Image, max_size: int = 1024) -> Tuple[Image.Image, float]:
    """
    Resize image if needed for AI processing (max dimension)

    Args:
        image: PIL Image
        max_size: Maximum dimension size

    Returns:
        Tuple of (resized image, scale factor)
    """
    width, height = image.size
    max_dim = max(width, height)

    if max_dim > max_size:
        scale = max_size / max_dim
        new_width = int(width * scale)
        new_height = int(height * scale)
        resized = image.resize((new_width, new_height), Image.Resampling.LANCZOS)
        return ensure_even_dimensions(resized), scale

    return ensure_even_dimensions(image), 1.0


def scale_bbox(bbox: Dict[str, int], scale: float) -> Dict[str, int]:
    """Scale bounding box coordinates"""
    return {
        'x': int(bbox['x'] * scale),
        'y': int(bbox['y'] * scale),
        'width': int(bbox['width'] * scale),
        'height': int(bbox['height'] * scale)
    }

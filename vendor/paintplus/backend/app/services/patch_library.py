import os
import shutil
from pathlib import Path
from typing import List, Optional
from PIL import Image
from datetime import datetime

from app.models.patch import Patch
from app.config import settings


class PatchLibraryService:
    """Service for managing the patch library"""

    def __init__(self, data_dir: str = None):
        self.data_dir = data_dir or settings.data_dir
        self.patch_library_dir = Path(self.data_dir) / "patch_library"
        self.patch_library_dir.mkdir(parents=True, exist_ok=True)

    def get_patch_path(self, patch_id: int) -> Path:
        """Get path to patch file"""
        return self.patch_library_dir / f"{patch_id}.png"

    def get_thumbnail_path(self, patch_id: int) -> Path:
        """Get path to patch thumbnail"""
        return self.patch_library_dir / f"{patch_id}_thumb.png"

    def create_thumbnail(self, image_path: Path, thumbnail_path: Path, size: tuple = (200, 200)):
        """Create a thumbnail from an image"""
        img = Image.open(image_path)
        img.thumbnail(size, Image.Resampling.LANCZOS)
        img.save(thumbnail_path, 'PNG')

    def save_patch_from_file(
        self,
        patch_id: int,
        image_path: str,
        create_thumb: bool = True
    ) -> str:
        """
        Save a patch from an existing file

        Args:
            patch_id: Patch ID
            image_path: Source image path
            create_thumb: Whether to create thumbnail

        Returns:
            Relative path to saved patch
        """
        patch_path = self.get_patch_path(patch_id)
        shutil.copy(image_path, patch_path)

        if create_thumb:
            thumbnail_path = self.get_thumbnail_path(patch_id)
            self.create_thumbnail(patch_path, thumbnail_path)

        return str(patch_path.relative_to(self.data_dir))

    def save_patch_from_bytes(
        self,
        patch_id: int,
        image_bytes: bytes,
        create_thumb: bool = True
    ) -> str:
        """
        Save a patch from bytes

        Args:
            patch_id: Patch ID
            image_bytes: Image data as bytes
            create_thumb: Whether to create thumbnail

        Returns:
            Relative path to saved patch
        """
        patch_path = self.get_patch_path(patch_id)

        # Save image
        with open(patch_path, 'wb') as f:
            f.write(image_bytes)

        if create_thumb:
            thumbnail_path = self.get_thumbnail_path(patch_id)
            self.create_thumbnail(patch_path, thumbnail_path)

        return str(patch_path.relative_to(self.data_dir))

    def save_ai_generated_patch(
        self,
        patch_id: int,
        edit_dir: Path
    ) -> str:
        """
        Save an AI-generated patch from an edit

        Args:
            patch_id: Patch ID
            edit_dir: Path to edit history directory

        Returns:
            Relative path to saved patch
        """
        # Use the AI-generated output (patch_out.png)
        source_path = edit_dir / "patch_out.png"
        return self.save_patch_from_file(patch_id, str(source_path))

    def save_manual_patch(
        self,
        patch_id: int,
        project_id: int,
        bbox: dict
    ) -> str:
        """
        Save a manually selected patch from current project image

        Args:
            patch_id: Patch ID
            project_id: Project ID
            bbox: Bounding box {x, y, width, height}

        Returns:
            Relative path to saved patch
        """
        from app.services.edit_service import EditService
        from app.utils.image_processing import crop_patch

        edit_service = EditService(self.data_dir)
        current_image_path = edit_service.get_current_image_path(project_id)

        # Load and crop current image
        img = Image.open(current_image_path)
        patch = crop_patch(img, bbox)

        # Save patch
        patch_path = self.get_patch_path(patch_id)
        patch.save(patch_path, 'PNG')

        # Create thumbnail
        thumbnail_path = self.get_thumbnail_path(patch_id)
        self.create_thumbnail(patch_path, thumbnail_path)

        return str(patch_path.relative_to(self.data_dir))

    def apply_patch_to_image(
        self,
        patch_id: int,
        target_image: Image.Image,
        bbox: dict,
        feather_px: int = 5
    ) -> Image.Image:
        """
        Apply a saved patch to a target image

        Args:
            patch_id: Patch ID to apply
            target_image: Target image to apply patch to
            bbox: Where to place the patch {x, y, width, height}
            feather_px: Feather radius for blending

        Returns:
            Image with patch applied
        """
        from app.utils.image_processing import insert_patch, create_feathered_mask
        from PIL import ImageOps

        # Load patch
        patch_path = self.get_patch_path(patch_id)
        patch = Image.open(patch_path).convert('RGBA')

        # Resize patch to match bbox if needed
        if patch.size != (bbox['width'], bbox['height']):
            patch = patch.resize((bbox['width'], bbox['height']), Image.Resampling.LANCZOS)

        # Create a soft-edged mask for the patch
        mask = Image.new('L', patch.size, 255)
        if feather_px > 0:
            mask = create_feathered_mask(mask, feather_px)

        # Apply mask to patch
        patch.putalpha(mask)

        # Insert patch into target image
        result = insert_patch(target_image, patch, bbox)

        return result

    def delete_patch(self, patch_id: int):
        """Delete a patch and its thumbnail"""
        patch_path = self.get_patch_path(patch_id)
        thumbnail_path = self.get_thumbnail_path(patch_id)

        if patch_path.exists():
            patch_path.unlink()

        if thumbnail_path.exists():
            thumbnail_path.unlink()

    def get_patch_size(self, patch_id: int) -> tuple:
        """Get patch dimensions"""
        patch_path = self.get_patch_path(patch_id)
        if not patch_path.exists():
            return (0, 0)

        img = Image.open(patch_path)
        return img.size

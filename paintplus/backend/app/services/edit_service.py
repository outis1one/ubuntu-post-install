import os
import json
from pathlib import Path
from typing import Dict, Optional
from datetime import datetime
from PIL import Image

from app.models.edit import Edit
from app.models.project import Project
from app.services.ai_provider import get_ai_provider
from app.utils.image_processing import (
    bytes_to_image,
    image_to_bytes,
    crop_patch,
    blend_patch,
    insert_patch,
    create_mask_from_selection,
    resize_for_ai,
    scale_bbox
)
from app.config import settings


class EditService:
    """Service for handling image edits"""

    def __init__(self, data_dir: str = None):
        self.data_dir = data_dir or settings.data_dir
        self.ai_provider = get_ai_provider()

    def get_project_dir(self, project_id: int) -> Path:
        """Get project directory path"""
        return Path(self.data_dir) / "projects" / str(project_id)

    def get_edit_dir(self, project_id: int, edit_id: int) -> Path:
        """Get edit history directory path"""
        return self.get_project_dir(project_id) / "history" / str(edit_id)

    def ensure_project_dir(self, project_id: int):
        """Ensure project directory structure exists"""
        project_dir = self.get_project_dir(project_id)
        project_dir.mkdir(parents=True, exist_ok=True)
        (project_dir / "history").mkdir(exist_ok=True)

    def get_current_image_path(self, project_id: int) -> Path:
        """Get path to current image"""
        return self.get_project_dir(project_id) / "current.png"

    def get_original_image_path(self, project_id: int) -> Path:
        """Get path to original image"""
        return self.get_project_dir(project_id) / "original.png"

    async def process_edit(
        self,
        project_id: int,
        edit_id: int,
        prompt: str,
        mode: str,
        selection_type: str,
        bbox: Dict[str, int],
        feather_px: int,
        selection_data: Optional[Dict] = None
    ) -> str:
        """
        Process an edit request

        Args:
            project_id: Project ID
            edit_id: Edit ID
            prompt: AI prompt
            mode: "A" or "B"
            selection_type: "rectangle", "ellipse", or "lasso"
            bbox: Bounding box {x, y, width, height}
            feather_px: Feather radius in pixels
            selection_data: Additional selection data (for lasso)

        Returns:
            Path to the result image
        """
        # Create edit directory
        edit_dir = self.get_edit_dir(project_id, edit_id)
        edit_dir.mkdir(parents=True, exist_ok=True)

        # Load current image
        current_image_path = self.get_current_image_path(project_id)
        full_image = Image.open(current_image_path).convert('RGBA')

        # Crop patch from current image
        original_patch = crop_patch(full_image, bbox)

        # Save original patch
        original_patch.save(edit_dir / "patch_in.png")

        # Create mask based on selection type
        mask = create_mask_from_selection(
            bbox['width'],
            bbox['height'],
            selection_type,
            selection_data or {}
        )

        # Save mask
        mask.save(edit_dir / "mask.png")

        # Resize patch and mask for AI if needed
        patch_for_ai, scale = resize_for_ai(original_patch)
        mask_for_ai = mask.resize(patch_for_ai.size, Image.Resampling.LANCZOS)

        # Prepare full image for mode B
        full_image_bytes = None
        if mode == "B":
            full_image_for_ai, _ = resize_for_ai(full_image)
            full_image_bytes = image_to_bytes(full_image_for_ai)

        # Call AI provider
        regenerated_patch_bytes = await self.ai_provider.edit_image(
            patch_image_bytes=image_to_bytes(patch_for_ai),
            mask_image_bytes=image_to_bytes(mask_for_ai),
            prompt=prompt,
            mode=mode,
            full_image_bytes=full_image_bytes
        )

        # Convert regenerated patch back to PIL Image
        regenerated_patch = bytes_to_image(regenerated_patch_bytes)

        # Resize back to original patch size if scaled
        if scale != 1.0:
            regenerated_patch = regenerated_patch.resize(
                original_patch.size,
                Image.Resampling.LANCZOS
            )

        # Save regenerated patch
        regenerated_patch.save(edit_dir / "patch_out.png")

        # Blend regenerated patch with original using mask
        blended_patch = blend_patch(
            original_patch,
            regenerated_patch,
            mask,
            feather_px
        )

        # Insert blended patch back into full image
        result_image = insert_patch(full_image, blended_patch, bbox)

        # Save result
        result_path = edit_dir / "result.png"
        result_image.save(result_path)

        # Update current image
        result_image.save(current_image_path)

        # Save metadata
        metadata = {
            'edit_id': edit_id,
            'project_id': project_id,
            'prompt': prompt,
            'mode': mode,
            'selection_type': selection_type,
            'bbox': bbox,
            'feather_px': feather_px,
            'selection_data': selection_data,
            'timestamp': datetime.utcnow().isoformat(),
            'ai_provider': settings.ai_provider
        }

        with open(edit_dir / "meta.json", 'w') as f:
            json.dump(metadata, f, indent=2)

        return str(result_path)

    def revert_to_edit(self, project_id: int, edit_id: int) -> str:
        """
        Revert project to a specific edit

        Args:
            project_id: Project ID
            edit_id: Edit ID to revert to

        Returns:
            Path to the reverted image
        """
        edit_dir = self.get_edit_dir(project_id, edit_id)
        result_path = edit_dir / "result.png"

        if not result_path.exists():
            raise FileNotFoundError(f"Edit {edit_id} result not found")

        # Copy result to current (preserve alpha channel)
        current_path = self.get_current_image_path(project_id)
        img = Image.open(result_path)
        # Preserve original mode to maintain transparency
        img.save(current_path, format='PNG')

        return str(current_path)

    def reset_to_original(self, project_id: int) -> str:
        """
        Reset project to original image

        Args:
            project_id: Project ID

        Returns:
            Path to the original image
        """
        original_path = self.get_original_image_path(project_id)
        current_path = self.get_current_image_path(project_id)

        if not original_path.exists():
            raise FileNotFoundError(f"Original image for project {project_id} not found")

        # Copy original to current (preserve alpha channel)
        img = Image.open(original_path)
        # Preserve original mode to maintain transparency
        img.save(current_path, format='PNG')

        return str(current_path)

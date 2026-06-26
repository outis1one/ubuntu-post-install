from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session
from typing import List, Optional
import json

from app.database import get_db
from app.models.patch import Patch
from app.models.project import Project
from app.models.edit import Edit
from app.schemas import PatchCreate, PatchResponse, PatchApply, StatusResponse
from app.services.patch_library import PatchLibraryService
from app.config import settings

router = APIRouter(prefix="/patches", tags=["patches"])


@router.post("/", response_model=PatchResponse)
async def create_patch(
    name: str = Form(...),
    description: Optional[str] = Form(None),
    source_type: str = Form(...),
    category: Optional[str] = Form(None),
    tags: Optional[str] = Form(None),
    source_project_id: Optional[int] = Form(None),
    source_edit_id: Optional[int] = Form(None),
    bbox: Optional[str] = Form(None),
    file: Optional[UploadFile] = File(None),
    db: Session = Depends(get_db)
):
    """
    Create a new patch in the library

    Source types:
    - ai_generated: From an edit (requires source_edit_id)
    - manual_selection: Selected from current image (requires source_project_id and bbox)
    - imported: Uploaded file (requires file)
    """

    # Validate source_type
    if source_type not in ["ai_generated", "manual_selection", "imported"]:
        raise HTTPException(status_code=400, detail="Invalid source_type")

    # Create patch record
    patch = Patch(
        name=name,
        description=description,
        source_type=source_type,
        source_project_id=source_project_id,
        source_edit_id=source_edit_id,
        tags=tags,
        category=category,
        file_path="",  # Will be set after saving
        user_id=None  # TODO: Add authentication
    )

    db.add(patch)
    db.commit()
    db.refresh(patch)

    # Save patch file based on source type
    patch_service = PatchLibraryService()

    try:
        if source_type == "ai_generated":
            # Get edit directory and save AI-generated patch
            if not source_edit_id:
                raise HTTPException(status_code=400, detail="source_edit_id required for ai_generated")

            edit = db.query(Edit).filter(Edit.id == source_edit_id).first()
            if not edit:
                raise HTTPException(status_code=404, detail="Edit not found")

            from app.services.edit_service import EditService
            edit_service = EditService()
            edit_dir = edit_service.get_edit_dir(edit.project_id, edit.id)

            file_path = patch_service.save_ai_generated_patch(patch.id, edit_dir)

            # Get dimensions
            width, height = patch_service.get_patch_size(patch.id)
            patch.width = width
            patch.height = height

        elif source_type == "manual_selection":
            # Save manually selected patch from current image
            if not source_project_id or not bbox:
                raise HTTPException(
                    status_code=400,
                    detail="source_project_id and bbox required for manual_selection"
                )

            project = db.query(Project).filter(Project.id == source_project_id).first()
            if not project:
                raise HTTPException(status_code=404, detail="Project not found")

            bbox_dict = json.loads(bbox) if isinstance(bbox, str) else bbox
            file_path = patch_service.save_manual_patch(patch.id, source_project_id, bbox_dict)

            patch.width = bbox_dict['width']
            patch.height = bbox_dict['height']

        elif source_type == "imported":
            # Save uploaded file
            if not file:
                raise HTTPException(status_code=400, detail="file required for imported")

            image_bytes = await file.read()
            file_path = patch_service.save_patch_from_bytes(patch.id, image_bytes)

            # Get dimensions
            width, height = patch_service.get_patch_size(patch.id)
            patch.width = width
            patch.height = height

        # Update patch with file path
        patch.file_path = file_path
        patch.thumbnail_path = str(patch_service.get_thumbnail_path(patch.id))
        db.commit()
        db.refresh(patch)

        return patch

    except Exception as e:
        # Cleanup on error
        patch_service.delete_patch(patch.id)
        db.delete(patch)
        db.commit()
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/", response_model=List[PatchResponse])
def list_patches(
    category: Optional[str] = None,
    tags: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db)
):
    """List patches in the library with optional filtering"""

    query = db.query(Patch)

    if category:
        query = query.filter(Patch.category == category)

    if tags:
        # Simple tag search (could be improved with full-text search)
        query = query.filter(Patch.tags.like(f"%{tags}%"))

    patches = query.offset(offset).limit(limit).all()
    return patches


@router.get("/{patch_id}", response_model=PatchResponse)
def get_patch(
    patch_id: int,
    db: Session = Depends(get_db)
):
    """Get patch details"""
    patch = db.query(Patch).filter(Patch.id == patch_id).first()
    if not patch:
        raise HTTPException(status_code=404, detail="Patch not found")
    return patch


@router.get("/{patch_id}/image")
def get_patch_image(
    patch_id: int,
    thumbnail: bool = False,
    db: Session = Depends(get_db)
):
    """Get patch image file"""
    patch = db.query(Patch).filter(Patch.id == patch_id).first()
    if not patch:
        raise HTTPException(status_code=404, detail="Patch not found")

    patch_service = PatchLibraryService()

    if thumbnail:
        file_path = patch_service.get_thumbnail_path(patch_id)
    else:
        file_path = patch_service.get_patch_path(patch_id)

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Patch image not found")

    return FileResponse(file_path, media_type="image/png")


@router.post("/apply", response_model=StatusResponse)
async def apply_patch(
    project_id: int = Form(...),
    patch_id: int = Form(...),
    bbox: str = Form(...),
    feather_px: int = Form(5),
    db: Session = Depends(get_db)
):
    """
    Apply a saved patch to a project image

    This creates a new edit in the project history.
    """
    # Verify project exists
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Verify patch exists
    patch = db.query(Patch).filter(Patch.id == patch_id).first()
    if not patch:
        raise HTTPException(status_code=404, detail="Patch not found")

    # Parse bbox
    bbox_dict = json.loads(bbox) if isinstance(bbox, str) else bbox

    # Load current image
    from app.services.edit_service import EditService
    from PIL import Image

    edit_service = EditService()
    current_image_path = edit_service.get_current_image_path(project_id)
    current_image = Image.open(current_image_path).convert('RGBA')

    # Apply patch
    patch_service = PatchLibraryService()
    result_image = patch_service.apply_patch_to_image(
        patch_id,
        current_image,
        bbox_dict,
        feather_px
    )

    # Save result as current image
    result_image.save(current_image_path)

    # Create edit record
    edit = Edit(
        project_id=project_id,
        mode="patch_library",
        prompt=f"Applied saved patch: {patch.name}",
        selection_type="rectangle",
        bbox_json=json.dumps(bbox_dict),
        feather_px=feather_px,
        ai_provider="patch_library",
        status="completed"
    )
    db.add(edit)
    db.commit()

    return StatusResponse(
        status="success",
        message=f"Applied patch '{patch.name}' to project",
        data={"edit_id": edit.id}
    )


@router.delete("/{patch_id}", response_model=StatusResponse)
def delete_patch(
    patch_id: int,
    db: Session = Depends(get_db)
):
    """Delete a patch from the library"""
    patch = db.query(Patch).filter(Patch.id == patch_id).first()
    if not patch:
        raise HTTPException(status_code=404, detail="Patch not found")

    # Delete files
    patch_service = PatchLibraryService()
    patch_service.delete_patch(patch_id)

    # Delete record
    db.delete(patch)
    db.commit()

    return StatusResponse(
        status="success",
        message=f"Deleted patch '{patch.name}'"
    )


@router.put("/{patch_id}", response_model=PatchResponse)
def update_patch(
    patch_id: int,
    name: Optional[str] = None,
    description: Optional[str] = None,
    category: Optional[str] = None,
    tags: Optional[str] = None,
    db: Session = Depends(get_db)
):
    """Update patch metadata"""
    patch = db.query(Patch).filter(Patch.id == patch_id).first()
    if not patch:
        raise HTTPException(status_code=404, detail="Patch not found")

    if name:
        patch.name = name
    if description is not None:
        patch.description = description
    if category:
        patch.category = category
    if tags is not None:
        patch.tags = tags

    db.commit()
    db.refresh(patch)

    return patch

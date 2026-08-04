from fastapi import APIRouter, Depends, HTTPException, Form
from sqlalchemy.orm import Session
from typing import Optional
from PIL import Image
from io import BytesIO
import os

from app.database import get_db
from app.models.project import Project
from app.schemas import TextToImageRequest, TextToImageResponse
from app.services.ai_provider import get_ai_provider
from app.services.edit_service import EditService
from app.config import settings

router = APIRouter(prefix="/generate", tags=["generate"])


@router.post("/text-to-image", response_model=TextToImageResponse)
async def text_to_image(
    prompt: str = Form(...),
    width: int = Form(1024),
    height: int = Form(1024),
    negative_prompt: Optional[str] = Form(None),
    ai_provider: Optional[str] = Form(None),
    ai_model: Optional[str] = Form(None),
    create_project: bool = Form(True),
    project_name: Optional[str] = Form(None),
    db: Session = Depends(get_db)
):
    """
    Generate an image from text prompt

    Args:
        prompt: Text description of desired image
        width: Image width (default 1024)
        height: Image height (default 1024)
        negative_prompt: What to avoid in generation
        ai_provider: Override default AI provider
        ai_model: Specific model to use
        create_project: Whether to create a new project with the result
        project_name: Name for the new project (if create_project=True)

    Returns:
        Generated image info and optionally project details
    """

    # Validate dimensions
    if width < 256 or width > 2048 or height < 256 or height > 2048:
        raise HTTPException(
            status_code=400,
            detail="Width and height must be between 256 and 2048"
        )

    # Get AI provider
    provider = get_ai_provider(ai_provider, ai_model)

    try:
        # Generate image
        image_bytes = await provider.text_to_image(
            prompt=prompt,
            width=width,
            height=height,
            model=ai_model,
            negative_prompt=negative_prompt
        )

        project_id = None
        image_url = None

        if create_project:
            # Create a new project
            project = Project(
                name=project_name or f"Generated: {prompt[:50]}",
                user_id=None  # TODO: Add authentication
            )
            db.add(project)
            db.commit()
            db.refresh(project)

            project_id = project.id

            # Save image as both original and current
            edit_service = EditService()
            edit_service.ensure_project_dir(project_id)

            original_path = edit_service.get_original_image_path(project_id)
            current_path = edit_service.get_current_image_path(project_id)

            # Save image
            img = Image.open(BytesIO(image_bytes))
            img.save(original_path, 'PNG')
            img.save(current_path, 'PNG')

            image_url = f"/projects/{project_id}/current"

        return TextToImageResponse(
            status="success",
            prompt=prompt,
            width=width,
            height=height,
            project_id=project_id,
            image_url=image_url,
            ai_provider=ai_provider or settings.ai_provider,
            ai_model=ai_model
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/layer/text-to-image", response_model=TextToImageResponse)
async def text_to_image_layer(
    project_id: int = Form(...),
    prompt: str = Form(...),
    width: int = Form(512),
    height: int = Form(512),
    x: int = Form(0),
    y: int = Form(0),
    negative_prompt: Optional[str] = Form(None),
    ai_provider: Optional[str] = Form(None),
    ai_model: Optional[str] = Form(None),
    db: Session = Depends(get_db)
):
    """
    Generate an image as a new layer in an existing project

    This generates a smaller image that can be placed as a layer
    on top of the current project canvas.
    """

    # Verify project exists
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Get AI provider
    provider = get_ai_provider(ai_provider, ai_model)

    try:
        # Generate image
        image_bytes = await provider.text_to_image(
            prompt=prompt,
            width=width,
            height=height,
            model=ai_model,
            negative_prompt=negative_prompt
        )

        # Save as temporary layer file
        edit_service = EditService()
        layers_dir = edit_service.get_project_dir(project_id) / "layers"
        layers_dir.mkdir(exist_ok=True)

        # Generate unique layer filename
        import time
        layer_filename = f"generated_{int(time.time())}.png"
        layer_path = layers_dir / layer_filename

        # Save layer image
        with open(layer_path, 'wb') as f:
            f.write(image_bytes)

        return TextToImageResponse(
            status="success",
            prompt=prompt,
            width=width,
            height=height,
            project_id=project_id,
            image_url=f"/projects/{project_id}/layers/{layer_filename}",
            layer_position={"x": x, "y": y},
            ai_provider=ai_provider or settings.ai_provider,
            ai_model=ai_model
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

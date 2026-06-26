from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from sqlalchemy.orm import Session
import json

from app.database import get_db
from app.models.project import Project
from app.models.edit import Edit
from app.schemas import EditRequest, EditResponse, StatusResponse
from app.services.edit_service import EditService
from app.config import settings

router = APIRouter(prefix="/edits", tags=["edits"])


async def process_edit_background(
    edit_id: int,
    project_id: int,
    request: EditRequest,
    db: Session
):
    """Background task to process edit"""
    edit_service = EditService()

    try:
        # Process the edit
        result_path = await edit_service.process_edit(
            project_id=project_id,
            edit_id=edit_id,
            prompt=request.prompt,
            mode=request.mode,
            selection_type=request.selection_type,
            bbox=request.bbox,
            feather_px=request.feather_px,
            selection_data=request.selection_data
        )

        # Update edit status
        edit = db.query(Edit).filter(Edit.id == edit_id).first()
        if edit:
            edit.status = "completed"
            db.commit()

    except Exception as e:
        # Update edit with error
        edit = db.query(Edit).filter(Edit.id == edit_id).first()
        if edit:
            edit.status = "failed"
            edit.error_message = str(e)
            db.commit()


@router.post("/projects/{project_id}/fix", response_model=EditResponse)
async def create_edit(
    project_id: int,
    request: EditRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db)
):
    """
    Create a new edit request (Fix button)

    This endpoint accepts the selection data and prompt,
    then processes the edit in the background.
    """
    # Verify project exists
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Validate mode
    if request.mode not in ["A", "B"]:
        raise HTTPException(status_code=400, detail="Mode must be 'A' or 'B'")

    # Validate selection type
    if request.selection_type not in ["rectangle", "ellipse", "lasso"]:
        raise HTTPException(status_code=400, detail="Invalid selection type")

    # Create edit record
    edit = Edit(
        project_id=project_id,
        mode=request.mode,
        prompt=request.prompt,
        selection_type=request.selection_type,
        bbox_json=json.dumps(request.bbox),
        feather_px=request.feather_px,
        ai_provider=settings.ai_provider,
        status="pending"
    )
    db.add(edit)
    db.commit()
    db.refresh(edit)

    # Process edit in background
    background_tasks.add_task(
        process_edit_background,
        edit.id,
        project_id,
        request,
        db
    )

    return edit


@router.get("/{edit_id}", response_model=EditResponse)
def get_edit(
    edit_id: int,
    db: Session = Depends(get_db)
):
    """Get edit details and status"""
    edit = db.query(Edit).filter(Edit.id == edit_id).first()
    if not edit:
        raise HTTPException(status_code=404, detail="Edit not found")
    return edit


@router.post("/projects/{project_id}/revert/{edit_id}", response_model=StatusResponse)
def revert_to_edit(
    project_id: int,
    edit_id: int,
    db: Session = Depends(get_db)
):
    """Revert project to a specific edit"""
    # Verify project exists
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Verify edit exists and belongs to project
    edit = db.query(Edit).filter(
        Edit.id == edit_id,
        Edit.project_id == project_id
    ).first()
    if not edit:
        raise HTTPException(status_code=404, detail="Edit not found")

    # Revert
    edit_service = EditService()
    try:
        result_path = edit_service.revert_to_edit(project_id, edit_id)
        return StatusResponse(
            status="success",
            message=f"Reverted to edit {edit_id}",
            data={"image_url": f"/projects/{project_id}/current"}
        )
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))


@router.post("/projects/{project_id}/reset", response_model=StatusResponse)
def reset_to_original(
    project_id: int,
    db: Session = Depends(get_db)
):
    """Reset project to original image"""
    # Verify project exists
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Reset
    edit_service = EditService()
    try:
        result_path = edit_service.reset_to_original(project_id)
        return StatusResponse(
            status="success",
            message="Reset to original image",
            data={"image_url": f"/projects/{project_id}/current"}
        )
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))

from fastapi import APIRouter, HTTPException, Depends
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session
from pathlib import Path

from app.database import get_db
from app.models.project import Project
from app.services.edit_service import EditService

router = APIRouter(prefix="/projects", tags=["images"])


@router.get("/{project_id}/original")
def get_original_image(
    project_id: int,
    db: Session = Depends(get_db)
):
    """Get the original uploaded image"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    edit_service = EditService()
    image_path = edit_service.get_original_image_path(project_id)

    if not image_path.exists():
        raise HTTPException(status_code=404, detail="Original image not found")

    return FileResponse(
        image_path,
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=3600"}
    )


@router.get("/{project_id}/current")
def get_current_image(
    project_id: int,
    db: Session = Depends(get_db)
):
    """Get the current edited image"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    edit_service = EditService()
    image_path = edit_service.get_current_image_path(project_id)

    if not image_path.exists():
        raise HTTPException(status_code=404, detail="Current image not found")

    return FileResponse(
        image_path,
        media_type="image/png",
        headers={"Cache-Control": "no-cache"}
    )


@router.get("/{project_id}/history/{edit_id}/result")
def get_edit_result(
    project_id: int,
    edit_id: int,
    db: Session = Depends(get_db)
):
    """Get the result image from a specific edit"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    edit_service = EditService()
    edit_dir = edit_service.get_edit_dir(project_id, edit_id)
    result_path = edit_dir / "result.png"

    if not result_path.exists():
        raise HTTPException(status_code=404, detail="Edit result not found")

    return FileResponse(
        result_path,
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=3600"}
    )

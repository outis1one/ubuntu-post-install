from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, status
from sqlalchemy.orm import Session
from typing import List
import shutil
from pathlib import Path
from PIL import Image

from app.database import get_db
from app.models.project import Project
from app.models.edit import Edit
from app.schemas import ProjectCreate, ProjectResponse, EditResponse, UploadResponse
from app.services.edit_service import EditService
from app.config import settings

router = APIRouter(prefix="/projects", tags=["projects"])


@router.post("/", response_model=ProjectResponse)
def create_project(
    project: ProjectCreate,
    db: Session = Depends(get_db)
):
    """Create a new project"""
    # For MVP, we'll use a default user_id of 1
    # In production, this would come from authentication
    user_id = 1

    db_project = Project(
        user_id=user_id,
        name=project.name
    )
    db.add(db_project)
    db.commit()
    db.refresh(db_project)

    # Create project directory
    edit_service = EditService()
    edit_service.ensure_project_dir(db_project.id)

    return db_project


@router.get("/", response_model=List[ProjectResponse])
def list_projects(
    skip: int = 0,
    limit: int = 100,
    db: Session = Depends(get_db)
):
    """List all projects"""
    projects = db.query(Project).offset(skip).limit(limit).all()
    return projects


@router.get("/{project_id}", response_model=ProjectResponse)
def get_project(
    project_id: int,
    db: Session = Depends(get_db)
):
    """Get a specific project"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    return project


@router.delete("/{project_id}")
def delete_project(
    project_id: int,
    db: Session = Depends(get_db)
):
    """Delete a project"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Delete project directory
    edit_service = EditService()
    project_dir = edit_service.get_project_dir(project_id)
    if project_dir.exists():
        shutil.rmtree(project_dir)

    db.delete(project)
    db.commit()

    return {"status": "success", "message": f"Project {project_id} deleted"}


@router.post("/{project_id}/upload", response_model=UploadResponse)
async def upload_image(
    project_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db)
):
    """Upload an image to a project"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Validate file type
    if not file.content_type.startswith('image/'):
        raise HTTPException(status_code=400, detail="File must be an image")

    # Create project directory
    edit_service = EditService()
    edit_service.ensure_project_dir(project_id)

    # Save original and current images
    original_path = edit_service.get_original_image_path(project_id)
    current_path = edit_service.get_current_image_path(project_id)

    # Read and validate image
    contents = await file.read()
    try:
        image = Image.open(BytesIO(contents))
        image = image.convert('RGBA')

        # Save images
        image.save(original_path, 'PNG')
        image.save(current_path, 'PNG')
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid image file: {str(e)}")

    return UploadResponse(
        project_id=project_id,
        original_url=f"/projects/{project_id}/original",
        current_url=f"/projects/{project_id}/current"
    )


@router.get("/{project_id}/edits", response_model=List[EditResponse])
def list_edits(
    project_id: int,
    db: Session = Depends(get_db)
):
    """List all edits for a project"""
    project = db.query(Project).filter(Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    edits = db.query(Edit).filter(Edit.project_id == project_id).order_by(Edit.created_at.desc()).all()
    return edits


from io import BytesIO

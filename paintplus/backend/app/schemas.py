from pydantic import BaseModel, EmailStr
from typing import Optional, List, Dict, Any
from datetime import datetime


# User schemas
class UserCreate(BaseModel):
    email: EmailStr
    password: str


class UserResponse(BaseModel):
    id: int
    email: str
    created_at: datetime

    class Config:
        from_attributes = True


# Project schemas
class ProjectCreate(BaseModel):
    name: str


class ProjectResponse(BaseModel):
    id: int
    user_id: int
    name: str
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


# Edit schemas
class EditRequest(BaseModel):
    prompt: str
    mode: str = "A"  # "A" or "B"
    selection_type: str  # "rectangle", "ellipse", "lasso"
    bbox: Dict[str, int]  # {x, y, width, height}
    feather_px: int = 0
    selection_data: Optional[Dict[str, Any]] = None


class EditResponse(BaseModel):
    id: int
    project_id: int
    created_at: datetime
    mode: str
    prompt: str
    selection_type: str
    bbox_json: str
    feather_px: int
    ai_provider: str
    status: str
    error_message: Optional[str] = None

    class Config:
        from_attributes = True


# Image upload
class UploadResponse(BaseModel):
    project_id: int
    original_url: str
    current_url: str


# Patch Library schemas
class PatchCreate(BaseModel):
    name: str
    description: Optional[str] = None
    source_type: str  # "ai_generated", "manual_selection", "imported"
    source_project_id: Optional[int] = None
    source_edit_id: Optional[int] = None
    category: Optional[str] = None
    tags: Optional[str] = None
    bbox: Optional[Dict[str, int]] = None


class PatchResponse(BaseModel):
    id: int
    name: str
    description: Optional[str]
    created_at: datetime
    source_type: str
    source_project_id: Optional[int]
    source_edit_id: Optional[int]
    width: int
    height: int
    tags: Optional[str]
    category: Optional[str]
    is_public: bool
    file_path: str
    thumbnail_path: Optional[str]

    class Config:
        from_attributes = True


class PatchApply(BaseModel):
    project_id: int
    patch_id: int
    bbox: Dict[str, int]
    feather_px: int = 5


# Text-to-Image schemas
class TextToImageRequest(BaseModel):
    prompt: str
    width: int = 1024
    height: int = 1024
    negative_prompt: Optional[str] = None
    ai_provider: Optional[str] = None
    ai_model: Optional[str] = None
    create_project: bool = True
    project_name: Optional[str] = None


class TextToImageResponse(BaseModel):
    status: str
    prompt: str
    width: int
    height: int
    project_id: Optional[int] = None
    image_url: Optional[str] = None
    layer_position: Optional[Dict[str, int]] = None
    ai_provider: str
    ai_model: Optional[str] = None


# Generic responses
class StatusResponse(BaseModel):
    status: str
    message: Optional[str] = None
    data: Optional[Any] = None

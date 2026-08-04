from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text, Boolean
from sqlalchemy.orm import relationship
from datetime import datetime
from app.database import Base


class Patch(Base):
    __tablename__ = "patches"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Source information
    source_type = Column(String, nullable=False)  # "ai_generated", "manual_selection", "imported"
    source_project_id = Column(Integer, ForeignKey("projects.id"), nullable=True)
    source_edit_id = Column(Integer, ForeignKey("edits.id"), nullable=True)

    # Patch metadata
    width = Column(Integer, nullable=False)
    height = Column(Integer, nullable=False)
    tags = Column(Text, nullable=True)  # Comma-separated tags
    category = Column(String, nullable=True)  # "hand", "face", "body", "object", "texture", etc.

    # Is this patch shared/public?
    is_public = Column(Boolean, default=False)

    # File path (relative to data dir)
    file_path = Column(String, nullable=False)
    thumbnail_path = Column(String, nullable=True)

    # Relationships
    user = relationship("User", back_populates="patches")
    source_project = relationship("Project")
    source_edit = relationship("Edit")

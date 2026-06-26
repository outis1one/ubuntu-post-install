from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from datetime import datetime
from app.database import Base


class Edit(Base):
    __tablename__ = "edits"

    id = Column(Integer, primary_key=True, index=True)
    project_id = Column(Integer, ForeignKey("projects.id"), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    mode = Column(String, nullable=False)  # "A" or "B"
    prompt = Column(Text, nullable=False)
    selection_type = Column(String, nullable=False)  # "rectangle", "ellipse", "lasso"
    bbox_json = Column(Text, nullable=False)  # JSON string of {x, y, width, height}
    feather_px = Column(Integer, default=0)
    ai_provider = Column(String, nullable=False)
    status = Column(String, nullable=False)  # "pending", "processing", "completed", "failed"
    error_message = Column(Text, nullable=True)

    # Relationships
    project = relationship("Project", back_populates="edits")

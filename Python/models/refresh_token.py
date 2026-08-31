from sqlalchemy import Column, String, DateTime, ForeignKey, Index
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from database import Base
import uuid


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    token_hash = Column(String(64), unique=True, nullable=False)
    expires_at = Column(DateTime, nullable=False)
    revoked_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=func.now(), nullable=False)

    user = relationship("User", back_populates="refresh_tokens")

    # Cobre tanto as buscas por usuario quanto a FK para users.id.
    __table_args__ = (
        Index("ix_refresh_tokens_user_id_created_at", "user_id", "created_at"),
    )

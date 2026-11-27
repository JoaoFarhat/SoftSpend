from sqlalchemy import Column, String, DateTime, ForeignKey, Integer
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from database import Base
import uuid


class CodigoRedefinicaoSenha(Base):
    """Codigo de 6 digitos do "Esqueci minha senha" (`services/redefinicao_senha_service.py`).

    So existe um por usuario: pedir de novo troca o anterior, herdando as
    tentativas erradas das ultimas 24 h. O codigo nunca e gravado, so o HMAC
    dele (`codigo_hash`). A linha e apagada quando a senha e trocada, ou
    quando vence sem nenhuma tentativa errada.
    """

    __tablename__ = "codigos_redefinicao_senha"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    codigo_hash = Column(String(64), nullable=False)
    expires_at = Column(DateTime, nullable=False)
    tentativas = Column(Integer, nullable=False, default=0, server_default="0")
    created_at = Column(DateTime, default=func.now(), nullable=False)

    user = relationship("User", back_populates="codigos_redefinicao")

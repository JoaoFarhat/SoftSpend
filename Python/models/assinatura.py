"""Assinatura do SoftSpend (AS1, `docs/publicacao.md` §1.4).

`assinaturas` tem uma linha por usuário, criada na primeira chamada de
`GET /api/assinatura`. O `app_account_token` é gerado aqui no servidor e o app
o repassa à compra na App Store (StoreKit), para a Apple devolvê-lo nas
transações e notificações. Datas em UTC sem fuso (mesmo padrão de
`refresh_tokens`).

`apple_notificacoes` guarda as notificações da App Store já processadas (o
`notification_uuid` é único, para ignorar reenvio). Só é preenchida na AS2.
"""

import uuid

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func

from database import Base


class Assinatura(Base):
    __tablename__ = "assinaturas"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(
        String(36),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    app_account_token = Column(
        String(36),
        nullable=False,
        default=lambda: str(uuid.uuid4()),
    )
    original_transaction_id = Column(String(64), nullable=True)
    produto = Column(String(100), nullable=True)
    # "Production" ou "Sandbox" (o servidor aceita os dois, §1.4).
    ambiente = Column(String(20), nullable=True)
    # Último estado conhecido (none, trial, active, grace, billing_retry,
    # expired, revoked). O acesso de verdade sai de
    # `assinatura_service.calcular_acesso`, que também olha as datas.
    status = Column(String(20), nullable=False, default="none", server_default="none")
    expira_em = Column(DateTime, nullable=True)
    carencia_ate = Column(DateTime, nullable=True)
    renovacao_automatica = Column(Boolean, nullable=True)
    atualizado_em = Column(
        DateTime, nullable=False, default=func.now(), onupdate=func.now()
    )

    usuario = relationship("User", back_populates="assinatura")

    # Mesmos nomes da migration a7c3e9f1b5d2.
    __table_args__ = (
        UniqueConstraint("user_id", name="uix_assinatura_user_id"),
        UniqueConstraint(
            "app_account_token", name="uix_assinatura_app_account_token"
        ),
        UniqueConstraint(
            "original_transaction_id",
            name="uix_assinatura_original_transaction_id",
        ),
    )


class AppleNotificacao(Base):
    __tablename__ = "apple_notificacoes"

    id = Column(Integer, primary_key=True, autoincrement=True)
    notification_uuid = Column(String(36), nullable=False)
    tipo = Column(String(50), nullable=False)
    subtipo = Column(String(50), nullable=True)
    original_transaction_id = Column(String(64), nullable=True, index=True)
    recebida_em = Column(DateTime, nullable=False, default=func.now())

    __table_args__ = (
        UniqueConstraint("notification_uuid", name="uix_apple_notificacao_uuid"),
    )

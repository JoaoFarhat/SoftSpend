from datetime import datetime, timezone

from sqlalchemy.orm import Session
from sqlalchemy import select
import models


def buscar_por_email(db: Session, email: str) -> models.User | None:
    return db.query(models.User).filter(models.User.email == email).first()


def buscar_por_username(db: Session, username: str) -> models.User | None:
    return db.query(models.User).filter(models.User.username == username).first()


def buscar_por_id(db: Session, user_id: str) -> models.User | None:
    return db.query(models.User).filter(models.User.id == user_id).first()


def criar_usuario(db: Session, usuario: models.User) -> models.User:
    db.add(usuario)
    db.flush()
    db.refresh(usuario)
    return usuario


def excluir_usuario_por_id(db: Session, user_id: str) -> None:
    usuario = buscar_por_id(db, user_id)
    if not usuario:
        raise ValueError("Usuario nao encontrado")
    db.delete(usuario)


def _agora_naive() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def buscar_refresh_token_por_hash(
    db: Session, token_hash: str, para_update: bool = False
) -> models.RefreshToken | None:
    query = db.query(models.RefreshToken).filter(
        models.RefreshToken.token_hash == token_hash
    )
    if para_update:
        query = query.with_for_update()
    return query.first()


def revogar_refresh_token_por_hash(db: Session, token_hash: str) -> None:
    db.query(models.RefreshToken).filter(
        models.RefreshToken.token_hash == token_hash,
        models.RefreshToken.revoked_at.is_(None),
    ).update({"revoked_at": _agora_naive()}, synchronize_session=False)


def revogar_todos_refresh_tokens_por_usuario(db: Session, user_id: str) -> None:
    db.query(models.RefreshToken).filter(
        models.RefreshToken.user_id == user_id,
        models.RefreshToken.revoked_at.is_(None),
    ).update({"revoked_at": _agora_naive()}, synchronize_session=False)


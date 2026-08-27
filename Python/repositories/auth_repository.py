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

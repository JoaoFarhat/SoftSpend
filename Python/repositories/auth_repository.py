from sqlalchemy.orm import Session
from sqlalchemy import select
import models


def buscar_por_email(db: Session, email: str) -> models.User | None:
    return db.query(models.User).filter(models.User.email == email).first()


def buscar_por_username(db: Session, username: str) -> models.User | None:
    return db.query(models.User).filter(models.User.username == username).first()


def buscar_por_id(db: Session, user_id: int) -> models.User | None:
    return db.query(models.User).filter(models.User.id == user_id).first()


def criar_usuario(db: Session, usuario: models.User) -> models.User:
    db.add(usuario)
    db.commit()
    db.refresh(usuario)
    return usuario

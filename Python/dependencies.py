from fastapi import Header, HTTPException, Depends
from sqlalchemy.orm import Session
from database import get_db
from repositories import auth_repository
from services import auth_service


def get_current_user(
    db: Session = Depends(get_db),
    authorization: str = Header(None),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Token nao fornecido")

    token = authorization.replace("Bearer ", "")
    user_id = auth_service.validar_token(token)

    if not user_id:
        raise HTTPException(status_code=401, detail="Token invalido ou expirado")

    usuario = auth_repository.buscar_por_id(db, user_id)
    if not usuario:
        raise HTTPException(status_code=401, detail="Usuario nao encontrado")

    return usuario


def get_current_user_id(usuario = Depends(get_current_user)) -> int:
    return usuario.id

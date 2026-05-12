from fastapi import Header, HTTPException
from services import auth_service


def get_current_user_id(authorization: str = Header(None)) -> int:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Token nao fornecido")

    token = authorization.replace("Bearer ", "")
    user_id = auth_service.validar_token(token)

    if not user_id:
        raise HTTPException(status_code=401, detail="Token invalido ou expirado")

    return user_id

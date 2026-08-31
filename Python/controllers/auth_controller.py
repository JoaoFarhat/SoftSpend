from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from database import get_db
from dependencies import get_current_user_id
from dtos.auth import (
    RegisterRequest,
    LoginRequest,
    RefreshRequest,
    LogoutRequest,
    AuthResponse,
)
from services import auth_service
from limiter import limiter

router = APIRouter(prefix="/auth", tags=["auth"])


def _montar_auth_response(usuario, access_token: str, refresh_token: str) -> AuthResponse:
    expires_in = auth_service.ACCESS_TOKEN_EXPIRE_MINUTES * 60
    return AuthResponse(
        id=usuario.id,
        nome=usuario.nome,
        username=usuario.username,
        email=usuario.email,
        access_token=access_token,
        refresh_token=refresh_token,
        token_type="bearer",
        expires_in=expires_in,
    )


@router.post("/register", response_model=AuthResponse)
@limiter.limit("3/minute")
def register(request: Request, dados: RegisterRequest, db: Session = Depends(get_db)):
    try:
        usuario = auth_service.registrar(db, dados)
        access_token = auth_service.criar_access_token(usuario.id)
        refresh_token = auth_service.criar_refresh_token(db, usuario.id)
        return _montar_auth_response(usuario, access_token, refresh_token)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/login", response_model=AuthResponse)
@limiter.limit("5/minute")
def login(request: Request, dados: LoginRequest, db: Session = Depends(get_db)):
    try:
        usuario, access_token, refresh_token = auth_service.login(db, dados)
        return _montar_auth_response(usuario, access_token, refresh_token)
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


@router.post("/refresh", response_model=AuthResponse)
@limiter.limit("5/minute")
def refresh(
    request: Request, dados: RefreshRequest, db: Session = Depends(get_db)
):
    try:
        usuario, access_token, refresh_token = auth_service.refresh_access_token(
            db, dados.refresh_token
        )
        return _montar_auth_response(usuario, access_token, refresh_token)
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


@router.post("/logout", status_code=204)
@limiter.limit("10/minute")
def logout(request: Request, dados: LogoutRequest, db: Session = Depends(get_db)):
    auth_service.logout(db, dados.refresh_token)
    return None


@router.delete("/conta", status_code=204)
@limiter.limit("10/minute")
def excluir_conta(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    auth_service.excluir_conta(db, user_id)
    return None

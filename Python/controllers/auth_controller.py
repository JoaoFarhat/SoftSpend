from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from database import get_db
from dtos.auth import RegisterRequest, LoginRequest, AuthResponse
from services import auth_service
from limiter import limiter

router = APIRouter(prefix="/auth", tags=["auth"])

@router.post("/register", response_model=AuthResponse)
@limiter.limit("3/minute")
def register(request: Request, dados: RegisterRequest, db: Session = Depends(get_db)):
    try:
        usuario = auth_service.registrar(db, dados)
        token = auth_service.criar_token(usuario.id)
        return AuthResponse(
            id=usuario.id,
            nome=usuario.nome,
            username=usuario.username,
            email=usuario.email,
            token=token
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/login", response_model=AuthResponse)
@limiter.limit("5/minute")
def login(request: Request, dados: LoginRequest, db: Session = Depends(get_db)):
    try:
        usuario, token = auth_service.login(db, dados)
        return AuthResponse(
            id=usuario.id,
            nome=usuario.nome,
            username=usuario.username,
            email=usuario.email,
            token=token
        )
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


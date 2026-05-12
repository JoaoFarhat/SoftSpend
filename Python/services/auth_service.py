from sqlalchemy.orm import Session
from passlib.context import CryptContext
from datetime import datetime, timedelta
from jose import JWTError, jwt
import os

import models
from repositories import auth_repository
from dtos.auth import RegisterRequest, LoginRequest

SECRET_KEY = os.getenv("SECRET_KEY")

if not SECRET_KEY:
    raise RuntimeError("SECRET_KEY não definida nas variáveis de ambiente")

ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 7

pwd_context = CryptContext(schemes=["argon2"], deprecated="auto")


def _hash_senha(senha: str) -> str:
    return pwd_context.hash(senha)


def _verificar_senha(senha: str, senha_hash: str) -> bool:
    return pwd_context.verify(senha, senha_hash)


def criar_token(user_id: int) -> str:
    expire = datetime.utcnow() + timedelta(days=ACCESS_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub": str(user_id),
        "exp": expire
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def registrar(db: Session, dados: RegisterRequest) -> models.User:
    if auth_repository.buscar_por_email(db, dados.email):
        raise ValueError("Email ja cadastrado")
    
    if auth_repository.buscar_por_username(db, dados.username):
        raise ValueError("Username ja cadastrado")
    
    novo_usuario = models.User(
        nome=dados.nome,
        username=dados.username,
        email=dados.email,
        senha_hash=_hash_senha(dados.senha)
    )
    
    return auth_repository.criar_usuario(db, novo_usuario)


def login(db: Session, dados: LoginRequest) -> tuple[models.User, str]:
    usuario = auth_repository.buscar_por_email(db, dados.email)
    
    if not usuario:
        raise ValueError("Credenciais invalidas")
    
    if not _verificar_senha(dados.senha, usuario.senha_hash):
        raise ValueError("Credenciais invalidas")
    
    token = criar_token(usuario.id)
    return usuario, token


def validar_token(token: str) -> int | None:
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id = int(payload.get("sub"))
        return user_id
    except JWTError:
        return None

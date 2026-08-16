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


JWT_ISSUER = os.getenv("JWT_ISSUER", "softspend-api")
JWT_AUDIENCE = os.getenv("JWT_AUDIENCE", "softspend-mobile")


def criar_token(user_id: str) -> str:
    now = datetime.utcnow()
    expire = now + timedelta(days=ACCESS_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub": user_id,
        "iat": now,
        "exp": expire,
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def registrar(db: Session, dados: RegisterRequest) -> models.User:
    if auth_repository.buscar_por_email(db, dados.email) or \
       auth_repository.buscar_por_username(db, dados.username):
        raise ValueError("Dados de cadastro ja em uso")
    
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


def validar_token(token: str) -> str | None:
    try:
        payload = jwt.decode(
            token,
            SECRET_KEY,
            algorithms=[ALGORITHM],
            issuer=JWT_ISSUER,
            audience=JWT_AUDIENCE,
        )
        return payload.get("sub")
    except JWTError:
        return None


def excluir_conta(db: Session, user_id: str) -> None:
    auth_repository.excluir_usuario_por_id(db, user_id)

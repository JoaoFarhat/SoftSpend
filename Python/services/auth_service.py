from sqlalchemy.orm import Session
from passlib.context import CryptContext
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import logging
import jwt
import os
import secrets

import models
from repositories import auth_repository
from dtos.auth import RegisterRequest, LoginRequest

logger = logging.getLogger(__name__)

SECRET_KEY = os.getenv("SECRET_KEY")

if not SECRET_KEY:
    raise RuntimeError("SECRET_KEY não definida nas variáveis de ambiente")
if len(SECRET_KEY) < 32:
    raise RuntimeError("SECRET_KEY deve ter pelo menos 32 caracteres")

ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "15"))
REFRESH_TOKEN_EXPIRE_DAYS = int(os.getenv("REFRESH_TOKEN_EXPIRE_DAYS", "7"))
REVOKE_OLD_REFRESH_TOKENS_ON_LOGIN = os.getenv(
    "REVOKE_OLD_REFRESH_TOKENS_ON_LOGIN", "false"
).lower() in ("1", "true", "yes")

REFRESH_TOKEN_SECRET_KEY = os.getenv("REFRESH_TOKEN_SECRET_KEY")

if not REFRESH_TOKEN_SECRET_KEY:
    raise RuntimeError(
        "REFRESH_TOKEN_SECRET_KEY não definida nas variáveis de ambiente"
    )
if len(REFRESH_TOKEN_SECRET_KEY) < 32:
    raise RuntimeError("REFRESH_TOKEN_SECRET_KEY deve ter pelo menos 32 caracteres")
if REFRESH_TOKEN_SECRET_KEY == SECRET_KEY:
    raise RuntimeError(
        "REFRESH_TOKEN_SECRET_KEY deve ser diferente de SECRET_KEY — usar a mesma "
        "chave faz o comprometimento do JWT expor tambem os refresh tokens"
    )

pwd_context = CryptContext(schemes=["argon2"], deprecated="auto")

JWT_ISSUER = os.getenv("JWT_ISSUER", "softspend-api")
JWT_AUDIENCE = os.getenv("JWT_AUDIENCE", "softspend-mobile")


def _hash_senha(senha: str) -> str:
    return pwd_context.hash(senha)


def _verificar_senha(senha: str, senha_hash: str) -> bool:
    return pwd_context.verify(senha, senha_hash)


def _hash_token(token: str) -> str:
    return hmac.new(
        REFRESH_TOKEN_SECRET_KEY.encode("utf-8"),
        token.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def _gerar_refresh_token() -> str:
    return secrets.token_urlsafe(32)


def criar_access_token(user_id: str) -> str:
    now = datetime.now(timezone.utc)
    expire = now + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {
        "sub": user_id,
        "iat": now,
        "exp": expire,
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "type": "access",
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def _utc_now_naive() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def criar_refresh_token(db: Session, user_id: str) -> str:
    raw_token = _gerar_refresh_token()
    token = models.RefreshToken(
        user_id=user_id,
        token_hash=_hash_token(raw_token),
        expires_at=_utc_now_naive() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS),
    )
    db.add(token)
    db.flush()
    return raw_token


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


def login(db: Session, dados: LoginRequest) -> tuple[models.User, str, str]:
    usuario = auth_repository.buscar_por_email(db, dados.email)

    if not usuario:
        raise ValueError("Credenciais invalidas")

    if not _verificar_senha(dados.senha, usuario.senha_hash):
        raise ValueError("Credenciais invalidas")

    if REVOKE_OLD_REFRESH_TOKENS_ON_LOGIN:
        auth_repository.revogar_todos_refresh_tokens_por_usuario(db, usuario.id)

    access_token = criar_access_token(usuario.id)
    refresh_token = criar_refresh_token(db, usuario.id)
    return usuario, access_token, refresh_token


def validar_token(token: str) -> str | None:
    try:
        payload = jwt.decode(
            token,
            SECRET_KEY,
            algorithms=[ALGORITHM],
            issuer=JWT_ISSUER,
            audience=JWT_AUDIENCE,
            options={"require": ["sub", "exp", "iss", "aud"]},
        )
        if payload.get("type") != "access":
            return None
        return payload.get("sub")
    except jwt.InvalidTokenError:
        return None


def refresh_access_token(
    db: Session, refresh_token: str
) -> tuple[models.User, str, str]:
    token_hash = _hash_token(refresh_token)
    # Bloqueia a linha ate o fim da transacao: duas requisicoes simultaneas com o
    # mesmo refresh token serializam aqui, entao a segunda ve revoked_at ja
    # preenchido em vez de emitir um segundo par de tokens valido.
    rt = auth_repository.buscar_refresh_token_por_hash(db, token_hash, para_update=True)
    agora = _utc_now_naive()

    if not rt:
        raise ValueError("Refresh token invalido ou expirado")

    # Reuso de token ja rotacionado indica vazamento: derruba todas as sessoes
    # do usuario (recomendacao do OAuth 2.0 Security BCP).
    if rt.revoked_at is not None:
        logger.warning(
            "Reuso de refresh token detectado para user_id=%s; revogando todas as sessoes",
            rt.user_id,
        )
        auth_repository.revogar_todos_refresh_tokens_por_usuario(db, rt.user_id)
        # O controller converte o erro em HTTP 401, e get_db faz rollback em
        # qualquer excecao. O commit explicito garante que a resposta de
        # seguranca (revogar a familia) sobreviva a esse rollback.
        db.commit()
        raise ValueError("Refresh token invalido ou expirado")

    if rt.expires_at <= agora:
        raise ValueError("Refresh token invalido ou expirado")

    usuario = auth_repository.buscar_por_id(db, rt.user_id)
    if not usuario:
        raise ValueError("Refresh token invalido ou expirado")

    rt.revoked_at = agora
    db.flush()

    access_token = criar_access_token(rt.user_id)
    novo_refresh_token = criar_refresh_token(db, rt.user_id)

    return usuario, access_token, novo_refresh_token


def logout(db: Session, refresh_token: str | None) -> None:
    if not refresh_token:
        return
    auth_repository.revogar_refresh_token_por_hash(db, _hash_token(refresh_token))


def excluir_conta(db: Session, user_id: str) -> None:
    auth_repository.excluir_usuario_por_id(db, user_id)

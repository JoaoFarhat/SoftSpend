"""Regra do "Esqueci minha senha" (rotas em `controllers/auth_controller.py`).

1. `pedir_codigo` gera um codigo de 6 digitos para o e-mail, se houver conta, e
   devolve o que o e-mail precisa; a rota responde igual exista a conta ou nao
   (nao revela quem tem conta). Pedido de novo antes de `REENVIO_SEGUNDOS` nao
   gera outro codigo.
2. `redefinir` confere e-mail + codigo, troca a senha e revoga todas as sessoes.
   Qualquer falha (sem conta, sem pedido, expirado, errado, tentativas
   esgotadas) e o mesmo `CodigoInvalido`.

Guarda so o HMAC do codigo, uma linha por usuario.
"""
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

import models
from repositories import auth_repository
from services import auth_service

VALIDADE_MINUTOS = 15
REENVIO_SEGUNDOS = 60
MAX_TENTATIVAS = 5

ERRO_CODIGO_INVALIDO = "invalid_reset_code"


class CodigoInvalido(ValueError):
    def __init__(self):
        super().__init__(ERRO_CODIGO_INVALIDO)


@dataclass(frozen=True)
class EnvioCodigo:
    """O que o e-mail precisa; so existe quando ha conta e um codigo novo."""

    email: str
    nome: str
    codigo: str


def _agora() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _hash_codigo(user_id: str, codigo: str) -> str:
    return hmac.new(
        auth_service.REFRESH_TOKEN_SECRET_KEY.encode("utf-8"),
        f"redefinicao:{user_id}:{codigo}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def _registro(db: Session, user_id: str) -> models.CodigoRedefinicaoSenha | None:
    return (
        db.query(models.CodigoRedefinicaoSenha)
        .filter(models.CodigoRedefinicaoSenha.user_id == user_id)
        .first()
    )


def pedir_codigo(db: Session, email: str, agora: datetime | None = None) -> EnvioCodigo | None:
    agora = agora or _agora()
    usuario = auth_repository.buscar_por_email(db, email)
    if usuario is None:
        return None

    anterior = _registro(db, usuario.id)
    if anterior is not None:
        if anterior.created_at and agora - anterior.created_at < timedelta(seconds=REENVIO_SEGUNDOS):
            return None
        db.delete(anterior)
        db.flush()

    codigo = f"{secrets.randbelow(10**6):06d}"
    db.add(
        models.CodigoRedefinicaoSenha(
            user_id=usuario.id,
            codigo_hash=_hash_codigo(usuario.id, codigo),
            expires_at=agora + timedelta(minutes=VALIDADE_MINUTOS),
            tentativas=0,
            created_at=agora,
        )
    )
    db.flush()
    return EnvioCodigo(email=usuario.email, nome=usuario.nome, codigo=codigo)


def redefinir(
    db: Session, email: str, codigo: str, nova_senha: str, agora: datetime | None = None
) -> None:
    agora = agora or _agora()
    usuario = auth_repository.buscar_por_email(db, email)
    if usuario is None:
        raise CodigoInvalido()

    registro = _registro(db, usuario.id)
    if registro is None:
        raise CodigoInvalido()

    if registro.expires_at <= agora:
        db.delete(registro)
        db.commit()  # a rota lanca depois, e o get_db desfaria a limpeza
        raise CodigoInvalido()

    if not hmac.compare_digest(registro.codigo_hash, _hash_codigo(usuario.id, codigo)):
        registro.tentativas = (registro.tentativas or 0) + 1
        if registro.tentativas >= MAX_TENTATIVAS:
            db.delete(registro)
        db.commit()  # idem: a tentativa errada precisa contar
        raise CodigoInvalido()

    usuario.senha_hash = auth_service._hash_senha(nova_senha)
    db.delete(registro)
    # Senha nova derruba todas as sessoes (e o access token delas, pelo `sid`).
    auth_repository.revogar_todos_refresh_tokens_por_usuario(db, usuario.id)

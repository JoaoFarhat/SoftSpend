"""Regra da assinatura (AS1, `docs/publicacao.md` §1.4).

`calcular_acesso` é o único caminho que decide o acesso: função pura, sem
banco e sem relógio, coberta por teste de tabela. A AS2 (JWS, webhook e App
Store Server API) só atualiza os campos da linha; quem decide é esta função.

`BILLING_ENFORCEMENT` é lido a cada chamada (padrão `off`): com `off`, todo
mundo tem acesso e nada bloqueia.
"""

import logging
import os
from datetime import datetime, timezone

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

import models

logger = logging.getLogger(__name__)

NONE = "none"
TRIAL = "trial"
ACTIVE = "active"
GRACE = "grace"
BILLING_RETRY = "billing_retry"
EXPIRED = "expired"
REVOKED = "revoked"

ESTADOS = (NONE, TRIAL, ACTIVE, GRACE, BILLING_RETRY, EXPIRED, REVOKED)

ERRO_SEM_ASSINATURA = "subscription_required"


class AssinaturaNecessaria(Exception):
    """Vira `403 {"detail": "subscription_required"}` (handler em `middlewares`).

    Não é `HTTPException` de propósito: o handler genérico da API troca
    `detail` por `error`, e o app precisa de `detail` para reconhecer o caso.
    """


def _utc_naive(momento: datetime | None) -> datetime | None:
    """O banco guarda UTC sem fuso; uma data com fuso é convertida."""
    if momento is None or momento.tzinfo is None:
        return momento
    return momento.astimezone(timezone.utc).replace(tzinfo=None)


def calcular_acesso(assinatura, agora: datetime) -> tuple[str, bool]:
    """Devolve `(status, tem_acesso)` da assinatura no instante `agora`.

    - Sem linha, ou linha sem compra (`status` `none`): `none`, sem acesso.
    - `revoked` (reembolso ou família removida) e `expired` gravados pela
      Apple valem como estão, sem acesso.
    - Antes de `expira_em` (estrito): `trial` se o período é o grátis, senão
      `active`; com acesso.
    - Depois de `expira_em` e antes de `carencia_ate` (estrito): `grace`, com
      acesso (a Apple ainda tenta cobrar).
    - Depois disso: `billing_retry` se a cobrança estava falhando (`grace` ou
      `billing_retry` gravados), senão `expired`; sem acesso.
    """
    if assinatura is None:
        return NONE, False

    gravado = assinatura.status or NONE
    if gravado == NONE:
        return NONE, False
    if gravado in (REVOKED, EXPIRED):
        return gravado, False

    agora = _utc_naive(agora)
    expira_em = _utc_naive(assinatura.expira_em)
    carencia_ate = _utc_naive(assinatura.carencia_ate)

    if expira_em is not None and agora < expira_em:
        return (TRIAL if gravado == TRIAL else ACTIVE), True
    if carencia_ate is not None and agora < carencia_ate:
        return GRACE, True
    if gravado in (GRACE, BILLING_RETRY):
        return BILLING_RETRY, False
    return EXPIRED, False


def cobranca_ligada() -> bool:
    """`BILLING_ENFORCEMENT=on` liga o bloqueio. Lido a cada requisição."""
    return os.getenv("BILLING_ENFORCEMENT", "off").strip().lower() == "on"


def agora_utc() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def buscar(db: Session, user_id: str) -> models.Assinatura | None:
    return (
        db.query(models.Assinatura)
        .filter(models.Assinatura.user_id == user_id)
        .first()
    )


def obter_ou_criar(db: Session, user_id: str) -> models.Assinatura:
    """Linha do usuário, criada com um `app_account_token` novo se faltar.

    Duas primeiras chamadas ao mesmo tempo esbarram no unique de `user_id`;
    a que perde desfaz só o savepoint e lê a linha da outra.
    """
    assinatura = buscar(db, user_id)
    if assinatura is not None:
        return assinatura
    try:
        with db.begin_nested():
            assinatura = models.Assinatura(user_id=user_id, status=NONE)
            db.add(assinatura)
    except IntegrityError:
        assinatura = buscar(db, user_id)
        if assinatura is None:
            raise
    return assinatura


def tem_acesso(db: Session, user_id: str, agora: datetime | None = None) -> bool:
    """Acesso efetivo: sempre `True` com o interruptor desligado."""
    if not cobranca_ligada():
        return True
    _, acesso = calcular_acesso(buscar(db, user_id), agora or agora_utc())
    return acesso


def estado(db: Session, user_id: str, agora: datetime | None = None) -> dict:
    """Corpo do `GET /api/assinatura` (cria a linha na primeira vez)."""
    assinatura = obter_ou_criar(db, user_id)
    status, acesso = calcular_acesso(assinatura, agora or agora_utc())
    return {
        "status": status,
        "tem_acesso": acesso or not cobranca_ligada(),
        "expira_em": assinatura.expira_em,
        "produto": assinatura.produto,
        "app_account_token": assinatura.app_account_token,
    }

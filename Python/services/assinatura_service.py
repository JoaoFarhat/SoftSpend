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

from sqlalchemy import func
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


# ============================================================ AS2: Apple
#
# `docs/assinatura.md` §2. `reconciliar` é o único caminho que grava o estado
# vindo da Apple; `/transacoes`, o webhook e o job diário só a chamam.


class AssinaturaDeOutraConta(Exception):
    """`409`: o token ou a compra pertence a outro usuário do SoftSpend."""


# Notificações que só ficam registradas (§2.4: "sem mudança").
SO_REGISTRA = frozenset(
    {
        "TEST",
        "REFUND_DECLINED",
        "PRICE_INCREASE",
        "CONSUMPTION_REQUEST",
        "ONE_TIME_CHARGE",
        "EXTERNAL_PURCHASE_TOKEN",
    }
)

BUNDLE_PADRAO = "br.com.softspend.app"
OFERTA_INTRODUTORIA = 1
TESTE_GRATIS = "FREE_TRIAL"


def _eh_teste_gratis(transacao) -> bool:
    """§2.6: o trial é a oferta introdutória grátis da Apple, nada mais."""
    return (
        transacao is not None
        and transacao.offer_type is not None
        and int(transacao.offer_type) == OFERTA_INTRODUTORIA
        and str(transacao.offer_discount_type or "").upper() == TESTE_GRATIS
    )


def traduzir_status(status_apple, transacao, renovacao, agora: datetime) -> str:
    """Estado do SoftSpend a partir do estado da Apple.

    Com o código de `Get All Subscription Statuses` (§2.4): 1 ativa, 2
    expirada, 3 nova tentativa de cobrança, 4 carência, 5 revogada. Sem o
    código (Apple fora do ar, só a notificação), deriva das datas.
    """
    agora = _utc_naive(agora)
    if status_apple is not None:
        codigo = int(status_apple)
        if codigo == 1:
            return TRIAL if _eh_teste_gratis(transacao) else ACTIVE
        if codigo == 2:
            return EXPIRED
        if codigo == 3:
            return BILLING_RETRY
        if codigo == 4:
            return GRACE
        if codigo == 5:
            return REVOKED
        raise ValueError(f"status da Apple desconhecido: {codigo}")

    if transacao.revogada_em is not None:
        return REVOKED
    expira_em = _utc_naive(transacao.expira_em)
    if expira_em is not None and agora < expira_em:
        return TRIAL if _eh_teste_gratis(transacao) else ACTIVE
    carencia = _utc_naive(renovacao.carencia_ate) if renovacao else None
    if carencia is not None and agora < carencia:
        return GRACE
    if renovacao is not None and renovacao.em_nova_tentativa:
        return BILLING_RETRY
    return EXPIRED


def reconciliar(
    db: Session,
    assinatura: models.Assinatura,
    transacao,
    renovacao,
    agora: datetime,
    status_apple: int | None = None,
    ambiente: str | None = None,
) -> models.Assinatura:
    """Grava na linha o estado que a Apple descreve (§2.5).

    Não consulta a Apple nem decide o acesso: só copia os campos e traduz o
    status. O acesso continua saindo de `calcular_acesso`, que olha as datas
    (um `active` com `expira_em` no passado já vale `expired`).
    """
    agora = _utc_naive(agora)
    assinatura.original_transaction_id = transacao.original_transaction_id
    assinatura.produto = transacao.produto
    if ambiente or transacao.ambiente:
        assinatura.ambiente = ambiente or transacao.ambiente
    assinatura.expira_em = _utc_naive(transacao.expira_em)
    assinatura.carencia_ate = _utc_naive(renovacao.carencia_ate) if renovacao else None
    if renovacao is not None and renovacao.renovacao_automatica is not None:
        assinatura.renovacao_automatica = renovacao.renovacao_automatica
    assinatura.status = traduzir_status(status_apple, transacao, renovacao, agora)
    assinatura.atualizado_em = agora
    db.add(assinatura)
    return assinatura


def _por_transacao_original(db: Session, original_transaction_id: str):
    return (
        db.query(models.Assinatura)
        .filter(models.Assinatura.original_transaction_id == original_transaction_id)
        .first()
    )


def _por_token(db: Session, token: str):
    return (
        db.query(models.Assinatura)
        .filter(func.lower(models.Assinatura.app_account_token) == token.lower())
        .first()
    )


def registrar_transacao(
    db: Session, user_id: str, jws: str, agora: datetime | None = None
) -> dict:
    """`POST /api/assinatura/transacoes` (§2.3). Devolve o corpo do GET.

    Lança `ComprovanteInvalido` (400), `AssinaturaDeOutraConta` (409),
    `AppleIndisponivel`/`AppleNaoConfigurada` (503). Nada é gravado antes
    da resposta da Apple.
    """
    from services import apple_service

    agora = agora or agora_utc()
    transacao, ambiente = apple_service.verificar_transacao(jws)

    bundle = os.getenv("APPLE_BUNDLE_ID", BUNDLE_PADRAO).strip() or BUNDLE_PADRAO
    if transacao.bundle_id != bundle:
        raise apple_service.ComprovanteInvalido("bundle")
    if transacao.tipo != apple_service.TIPO_ASSINATURA:
        raise apple_service.ComprovanteInvalido("tipo")
    if transacao.produto not in apple_service.PRODUTOS:
        raise apple_service.ComprovanteInvalido("produto")
    original = transacao.original_transaction_id
    if not original:
        raise apple_service.ComprovanteInvalido("sem originalTransactionId")

    assinatura = buscar(db, user_id)
    if transacao.app_account_token:
        if assinatura is None or (
            assinatura.app_account_token.lower() != transacao.app_account_token.lower()
        ):
            raise AssinaturaDeOutraConta()
    else:
        # Restaurar compras de antes do token, ou canal externo (§2.3).
        logger.info("Transação sem appAccountToken recebida em /transacoes")

    dono = _por_transacao_original(db, original)
    if dono is not None and dono.user_id != user_id:
        raise AssinaturaDeOutraConta()

    estado_apple = apple_service.obter_cliente_apple(ambiente).status(original)

    if assinatura is None:
        assinatura = obter_ou_criar(db, user_id)
    if estado_apple is not None:
        reconciliar(
            db, assinatura, estado_apple.transacao, estado_apple.renovacao, agora,
            status_apple=estado_apple.status, ambiente=ambiente,
        )
    else:
        reconciliar(db, assinatura, transacao, None, agora, ambiente=ambiente)
    try:
        db.commit()
    except IntegrityError:
        # Outra conta ligou a mesma compra no mesmo instante.
        db.rollback()
        raise AssinaturaDeOutraConta() from None
    return estado(db, user_id, agora)


def processar_notificacao(
    db: Session, signed_payload: str, agora: datetime | None = None
) -> str:
    """`POST /api/webhooks/apple` (§2.3). Devolve o que foi feito, para log.

    A notificação é só gatilho: o estado vem de `Get All Subscription
    Statuses`. Com a Apple fora do ar, usa a própria notificação só se for
    mais nova que `atualizado_em`. O `notificationUUID` só é gravado junto
    com o resultado (no mesmo commit); falha interna não o deixa gravado.
    """
    from services import apple_service

    agora = agora or agora_utc()
    notificacao, ambiente = apple_service.verificar_notificacao(signed_payload)
    if not notificacao.uuid or not notificacao.tipo:
        raise apple_service.ComprovanteInvalido("notificação sem uuid ou tipo")

    repetida = (
        db.query(models.AppleNotificacao)
        .filter(models.AppleNotificacao.notification_uuid == notificacao.uuid)
        .first()
    )
    if repetida is not None:
        return "repetida"

    transacao = notificacao.transacao
    original = transacao.original_transaction_id if transacao else None
    registro = models.AppleNotificacao(
        notification_uuid=notificacao.uuid,
        tipo=notificacao.tipo,
        subtipo=notificacao.subtipo,
        original_transaction_id=original or None,
        recebida_em=agora,
    )

    resultado = "registrada"
    assinatura = None
    if notificacao.tipo not in SO_REGISTRA and transacao is not None:
        if original:
            assinatura = _por_transacao_original(db, original)
        if assinatura is None and transacao.app_account_token:
            assinatura = _por_token(db, transacao.app_account_token)
        if assinatura is None:
            resultado = "desconhecida"

    if assinatura is not None:
        try:
            estado_apple = apple_service.obter_cliente_apple(ambiente).status(original)
        except apple_service.AppleIndisponivel:
            estado_apple = None
            assinada = _utc_naive(notificacao.assinada_em)
            ultima = _utc_naive(assinatura.atualizado_em)
            if assinada is not None and (ultima is None or assinada > ultima):
                reconciliar(
                    db, assinatura, transacao, notificacao.renovacao, agora,
                    status_apple=notificacao.status, ambiente=ambiente,
                )
                resultado = "reconciliada_pela_notificacao"
            else:
                resultado = "antiga_ignorada"
        else:
            if estado_apple is not None:
                reconciliar(
                    db, assinatura, estado_apple.transacao, estado_apple.renovacao,
                    agora, status_apple=estado_apple.status, ambiente=ambiente,
                )
                resultado = "reconciliada"
            else:
                resultado = "sem_estado_na_apple"

    db.add(registro)
    try:
        db.commit()
    except IntegrityError:
        # A mesma notificação chegou duas vezes ao mesmo tempo.
        db.rollback()
        return "repetida"
    return resultado

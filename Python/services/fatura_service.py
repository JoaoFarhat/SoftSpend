"""Gravação, prévia de conciliação e exclusão de faturas importadas por arquivo.

Spec: `docs/cartao-sem-open-finance.md` §2.5 e §2.6. A fatura reusa as tabelas
do Open Finance sem conexão Pluggy: o cartão é `origem = 'FATURA'` com
`conexao_id` NULL, achado ou criado por (user_id, emissor, final do cartão);
a fatura, por (cartão, vencimento). A deduplicação das compras é o
`transaction_id` determinístico (`fatura:` + sha256), então reimportar o
mesmo arquivo não duplica nada.
"""

import hashlib
import uuid
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, time, timezone
from decimal import Decimal

from sqlalchemy.orm import Session

import models
from dtos.fatura import FaturaLida, MatchPrevia
from services import open_finance_reconciliation_service
from services.fatura_arquivo_service import (
    ErroFatura,
    MAXIMO_COMPRAS,
    VALOR_MAXIMO_COMPRA,
)

ORIGEM_FATURA = "FATURA"

# Na tabela, compras viram DEBIT (o filtro de conciliação só aceita DEBIT/NULL,
# então estornos e encargos nunca casam com gastos).
_TIPO_PARA_TYPE = {"COMPRA": "DEBIT", "ESTORNO": "CREDIT", "ENCARGO": "FEE"}


@dataclass
class _CompraComoTransacao:
    """Adapta `CompraLida` ao formato que `_pontuacao` espera."""

    amount: Decimal | None
    date: date | None
    merchant_name: str | None
    description: str | None = None
    description_raw: str | None = None


# -------------------------------------------------------------- prévia


def _data_da_coluna(valor) -> date | None:
    if valor is None:
        return None
    return valor.date() if isinstance(valor, datetime) else valor


def marcar_previa(
    session: Session, user_id: str, ciclo_id: int, lida: FaturaLida
) -> None:
    """Preenche `dentro_da_viagem`, `dia_id` e `match` de cada compra da prévia.

    As compras dentro das datas da viagem são pontuadas contra os gastos
    vivos do ciclo pela mesma `_pontuacao` da conciliação real, com
    atribuição gulosa pela maior pontuação: um gasto casa com uma compra só
    e vice-versa. Gastos já vinculados (`open_finance_match`) não entram.
    """
    ciclo = (
        session.query(models.Ciclo)
        .filter(
            models.Ciclo.id == ciclo_id,
            models.Ciclo.id_usuario == user_id,
        )
        .first()
    )
    if ciclo is None:
        raise ErroFatura(404, "Ciclo não encontrado")

    dias = [
        (dia, data)
        for dia in ciclo.dias
        if (data := _data_da_coluna(dia.data)) is not None
    ]
    if not dias:
        return

    primeira_data = min(data for _, data in dias)
    ultima_data = max(data for _, data in dias)
    dia_por_data = {data: dia.id for dia, data in dias}
    gastos = [
        gasto
        for dia, _ in dias
        for gasto in dia.gastos
        if gasto.open_finance_match is None
    ]

    pares: dict[int, list] = {}
    for i, compra in enumerate(lida.compras):
        if compra.data is None:
            continue
        if primeira_data <= compra.data <= ultima_data:
            compra.dentro_da_viagem = True
            compra.dia_id = dia_por_data.get(compra.data)
        if compra.tipo != "COMPRA" or not compra.dentro_da_viagem:
            continue
        transacao = _CompraComoTransacao(
            amount=compra.valor,
            date=compra.data,
            merchant_name=compra.descricao,
        )
        for gasto in gastos:
            score = open_finance_reconciliation_service._pontuacao(
                gasto, transacao
            )
            if score is not None:
                pares.setdefault(i, []).append((score, gasto))

    # Guloso: a compra com a maior melhor pontuação escolhe primeiro.
    ordem = sorted(
        pares, key=lambda i: (-max(s for s, _ in pares[i]), i)
    )
    usados: set[int] = set()
    for i in ordem:
        candidatos = sorted(
            ((s, g) for s, g in pares[i] if g.id not in usados),
            key=lambda par: (-par[0], par[1].id),
        )
        if not candidatos:
            continue
        score, gasto = candidatos[0]
        empate = len(candidatos) > 1 and candidatos[1][0] == score
        if score >= 80 and not empate:
            status = open_finance_reconciliation_service.STATUS_AUTO_MATCHED
        elif score >= 65:
            status = open_finance_reconciliation_service.STATUS_REVIEW
        else:
            continue
        usados.add(gasto.id)
        lida.compras[i].match = MatchPrevia(
            gasto_id=gasto.id, score=score, status=status
        )


# ------------------------------------------------------------ gravação


def _meia_noite(dia: date | None) -> datetime | None:
    return datetime.combine(dia, time.min, tzinfo=timezone.utc) if dia else None


def _cartao_importado(
    session: Session, user_id: str, emissor: str | None, final_cartao: str | None
) -> models.CreditCardAccount:
    """Acha ou cria o cartão importado por (user_id, emissor, final)."""
    emissor = (emissor or "").strip()[:255] or None
    final = (final_cartao or "").strip()[:4] or None
    cartao = (
        session.query(models.CreditCardAccount)
        .filter(
            models.CreditCardAccount.user_id == user_id,
            models.CreditCardAccount.origem == ORIGEM_FATURA,
            models.CreditCardAccount.institution_name == emissor,
            models.CreditCardAccount.number_last4 == final,
        )
        .first()
    )
    if cartao is None:
        partes = [emissor or "Cartão importado"]
        if final:
            partes.append(f"•••• {final}")
        cartao = models.CreditCardAccount(
            user_id=user_id,
            conexao_id=None,
            origem=ORIGEM_FATURA,
            account_id=f"fatura:{uuid.uuid4()}",
            institution_name=emissor,
            number_last4=final,
            name=" ".join(partes)[:255],
            currency_code="BRL",
        )
        session.add(cartao)
        session.flush()
    return cartao


def _fatura_importada(
    session: Session, cartao: models.CreditCardAccount, lida: FaturaLida
) -> models.CreditCardBill:
    """Acha a fatura por (cartão, vencimento); se o total mudou, atualiza."""
    vencimento = _meia_noite(lida.vencimento)
    fatura = (
        session.query(models.CreditCardBill)
        .filter(
            models.CreditCardBill.cartao_id == cartao.id,
            models.CreditCardBill.due_date == vencimento,
        )
        .first()
    )
    if fatura is None:
        fatura = models.CreditCardBill(
            cartao_id=cartao.id,
            user_id=cartao.user_id,
            bill_id=f"fatura:{uuid.uuid4()}",
        )
        session.add(fatura)
    fatura.due_date = vencimento
    fatura.closing_date = _meia_noite(lida.fechamento)
    fatura.total_amount = lida.total_fatura
    fatura.currency_code = lida.moeda
    session.flush()
    return fatura


def _compra_valida(compra) -> bool:
    return (
        compra.data is not None
        and compra.valor is not None
        and Decimal("0") < compra.valor <= VALOR_MAXIMO_COMPRA
        and bool(compra.descricao and compra.descricao.strip())
    )


def _transaction_id(user_id: str, account_id: str, compra, ordem: int) -> str:
    """`fatura:` + sha256 estável da compra, para deduplicar importações.

    Campos: user_id | cartão | data | valor | descrição normalizada |
    parcela | tipo | ordem entre iguais (§2.6 — o tipo evita que um estorno
    idêntico a uma compra seja confundido com ela; a ordem desempata duas
    compras idênticas no mesmo dia). O hexdigest é truncado para caber no
    VARCHAR(64) da coluna.
    """
    parcela = f"{compra.parcela_atual or ''}/{compra.parcela_total or ''}"
    base = "|".join(
        [
            user_id,
            account_id,
            compra.data.isoformat(),
            str(compra.valor.quantize(Decimal("0.01"))),
            open_finance_reconciliation_service._normalizar_texto(
                compra.descricao
            ),
            parcela,
            compra.tipo,
            str(ordem),
        ]
    )
    digest = hashlib.sha256(base.encode("utf-8")).hexdigest()
    return f"fatura:{digest[:57]}"


def gravar_fatura(
    session: Session, user_id: str, lida: FaturaLida
) -> models.CreditCardBill:
    """Grava a fatura e as compras enviadas, de forma idempotente.

    Só as compras que o app mandou (as que a pessoa deixou na conferência)
    são gravadas; compras repetidas de uma reimportação são puladas.
    """
    if len(lida.compras) > MAXIMO_COMPRAS:
        raise ErroFatura(
            413, f"Fatura com mais de {MAXIMO_COMPRAS} compras"
        )

    cartao = _cartao_importado(
        session, user_id, lida.emissor, lida.final_cartao
    )
    fatura = _fatura_importada(session, cartao, lida)

    ordens: Counter = Counter()
    pendentes: list[tuple[str, object]] = []
    for compra in lida.compras:
        if not _compra_valida(compra):
            continue
        chave = (
            compra.data,
            compra.valor,
            open_finance_reconciliation_service._normalizar_texto(
                compra.descricao
            ),
            compra.parcela_atual,
            compra.parcela_total,
            compra.tipo,
        )
        ordem = ordens[chave]
        ordens[chave] += 1
        pendentes.append(
            (_transaction_id(user_id, cartao.account_id, compra, ordem), compra)
        )

    existentes = set()
    if pendentes:
        existentes = {
            transaction_id
            for (transaction_id,) in session.query(
                models.CreditCardTransaction.transaction_id
            )
            .filter(
                models.CreditCardTransaction.transaction_id.in_(
                    [txid for txid, _ in pendentes]
                )
            )
            .all()
        }

    agora = datetime.now(timezone.utc)
    for transaction_id, compra in pendentes:
        if transaction_id in existentes:
            continue
        metadata = {
            chave: valor
            for chave, valor in {
                "parcela_atual": compra.parcela_atual,
                "parcela_total": compra.parcela_total,
                "valor_original": compra.valor_original,
            }.items()
            if valor is not None
        }
        session.add(
            models.CreditCardTransaction(
                cartao_id=cartao.id,
                fatura_id=fatura.id,
                user_id=user_id,
                transaction_id=transaction_id,
                description=compra.descricao.strip()[:255],
                description_raw=compra.descricao.strip()[:500],
                merchant_name=compra.descricao.strip()[:255],
                amount=compra.valor,
                amount_in_account_currency=compra.valor,
                currency_code=lida.moeda,
                date=_meia_noite(compra.data),
                category=compra.categoria.value,
                status="POSTED",
                type=_TIPO_PARA_TYPE.get(compra.tipo, "DEBIT"),
                credit_card_metadata=metadata or None,
                last_seen_at=agora,
            )
        )
    session.flush()
    return fatura


# ----------------------------------------------------- listar e apagar


def _query_importadas(session: Session, user_id: str):
    return session.query(models.CreditCardBill).join(
        models.CreditCardAccount,
        models.CreditCardBill.cartao_id == models.CreditCardAccount.id,
    ).filter(
        models.CreditCardBill.user_id == user_id,
        models.CreditCardAccount.origem == ORIGEM_FATURA,
    )


def listar_importadas(session: Session, user_id: str):
    return (
        _query_importadas(session, user_id)
        .order_by(models.CreditCardBill.due_date.desc())
        .all()
    )


def buscar_importada(session: Session, user_id: str, fatura_id: int):
    return (
        _query_importadas(session, user_id)
        .filter(models.CreditCardBill.id == fatura_id)
        .first()
    )


def apagar_importada(session: Session, fatura: models.CreditCardBill) -> None:
    """Apaga a fatura importada, suas compras e vínculos (os gastos ficam)."""
    transacoes = (
        session.query(models.CreditCardTransaction)
        .filter(models.CreditCardTransaction.fatura_id == fatura.id)
        .all()
    )
    for transacao in transacoes:
        session.delete(transacao)  # a cascata do ORM leva o match junto
    session.delete(fatura)
    session.flush()

import re
import unicodedata
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from difflib import SequenceMatcher

from sqlalchemy import or_
from sqlalchemy.orm import Session

import models
from repositories import open_finance_repository

STATUS_AUTO_MATCHED = "AUTO_MATCHED"
STATUS_REVIEW = "REVIEW"


def _normalizar_texto(valor: str | None) -> str:
    if not valor:
        return ""
    texto = unicodedata.normalize("NFD", valor)
    texto = texto.encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", " ", texto.lower()).strip()


def _pontuacao_texto(gasto: models.Gasto, transacao) -> int:
    titulo = _normalizar_texto(gasto.titulo)
    descricao = _normalizar_texto(
        transacao.merchant_name or transacao.description or transacao.description_raw
    )
    if not titulo or not descricao:
        return 0
    if titulo in descricao or descricao in titulo:
        return 20
    return int(SequenceMatcher(None, titulo, descricao).ratio() * 20)


def _data_gasto(gasto: models.Gasto):
    if not gasto.dia or not gasto.dia.data:
        return None
    data = gasto.dia.data
    return data.date() if isinstance(data, datetime) else data


def _pontuacao(gasto: models.Gasto, transacao) -> int | None:
    if gasto.valor is None or transacao.amount is None:
        return None
    if Decimal(str(gasto.valor)) != Decimal(str(transacao.amount)):
        return None

    data_gasto = _data_gasto(gasto)
    if not data_gasto or not transacao.date:
        return None

    diferenca_dias = (transacao.date.date() - data_gasto).days
    if diferenca_dias < -1 or diferenca_dias > 5:
        return None

    pontos = 60
    if diferenca_dias == 0:
        pontos += 20
    elif abs(diferenca_dias) == 1:
        pontos += 15
    elif abs(diferenca_dias) == 2:
        pontos += 10
    else:
        pontos += 5

    pontos += _pontuacao_texto(gasto, transacao)
    return min(pontos, 100)


def _candidatos(db: Session, gasto: models.Gasto, user_id: str):
    data_gasto = _data_gasto(gasto)
    if not data_gasto or gasto.valor is None:
        return []

    inicio = datetime.combine(
        data_gasto - timedelta(days=1), datetime.min.time(), timezone.utc
    )
    fim = datetime.combine(
        data_gasto + timedelta(days=6), datetime.min.time(), timezone.utc
    )
    return (
        db.query(models.CreditCardTransaction)
        .outerjoin(
            models.ExpenseTransactionMatch,
            models.ExpenseTransactionMatch.cartao_transacao_id
            == models.CreditCardTransaction.id,
        )
        .filter(
            models.CreditCardTransaction.user_id == user_id,
            models.CreditCardTransaction.amount == gasto.valor,
            models.CreditCardTransaction.date >= inicio,
            models.CreditCardTransaction.date < fim,
            or_(
                models.CreditCardTransaction.type.is_(None),
                models.CreditCardTransaction.type == "DEBIT",
            ),
            models.ExpenseTransactionMatch.id.is_(None),
        )
        .all()
    )


def _match_continua_valido(match: models.ExpenseTransactionMatch) -> bool:
    return _pontuacao(match.gasto, match.transacao) is not None


def conciliar_gasto(
    db: Session, gasto: models.Gasto, user_id: str
) -> models.ExpenseTransactionMatch | None:
    if gasto.open_finance_match:
        if _match_continua_valido(gasto.open_finance_match):
            return gasto.open_finance_match
        match = gasto.open_finance_match
        gasto.open_finance_match = None
        if match.transacao:
            match.transacao.open_finance_match = None
        open_finance_repository.remover_match(db, match)

    candidatos = []
    for transacao in _candidatos(db, gasto, user_id):
        score = _pontuacao(gasto, transacao)
        if score is not None:
            candidatos.append((score, transacao))

    if not candidatos:
        return None

    candidatos.sort(key=lambda item: item[0], reverse=True)
    score, transacao = candidatos[0]
    empate = len(candidatos) > 1 and candidatos[1][0] == score

    if score >= 80 and not empate:
        status = STATUS_AUTO_MATCHED
    elif score >= 65:
        status = STATUS_REVIEW
    else:
        return None

    match = open_finance_repository.criar_match(
        db, gasto, transacao, status=status, score=score
    )
    gasto.open_finance_match = match
    transacao.open_finance_match = match
    return match


def conciliar_usuario(db: Session, user_id: str) -> int:
    for match in open_finance_repository.listar_matches_usuario(db, user_id):
        if not _match_continua_valido(match):
            if match.gasto:
                match.gasto.open_finance_match = None
            if match.transacao:
                match.transacao.open_finance_match = None
            open_finance_repository.remover_match(db, match)

    total = 0
    for gasto in open_finance_repository.listar_gastos_sem_match(db, user_id):
        if conciliar_gasto(db, gasto, user_id):
            total += 1
    return total

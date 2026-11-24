from decimal import Decimal

from sqlalchemy import func
from sqlalchemy.orm import Session, joinedload
import models

def criar_gasto(db: Session, gasto: models.Gasto):
    db.add(gasto)
    db.flush()
    return gasto

def remover_gasto(db: Session, gasto: models.Gasto):
    db.delete(gasto)

def atualizar_gasto(db: Session, gasto: models.Gasto):
    db.flush()
    db.refresh(gasto)
    return gasto

def find_gasto(db: Session, gasto_id: int):
    return db.query(models.Gasto).filter(models.Gasto.id == gasto_id).first()


def find_gasto_for_update(db: Session, gasto_id: int):
    return (
        db.query(models.Gasto)
        .filter(models.Gasto.id == gasto_id)
        .with_for_update()
        .first()
    )


def find_by_client_id(db: Session, client_id: str, dia_id: int, para_atualizar: bool = False):
    # `para_atualizar`: leitura com bloqueio, que vê a linha recém-gravada por
    # outro pedido mesmo em REPEATABLE READ (ver `ciclo_repository`).
    query = db.query(models.Gasto).filter(
        models.Gasto.client_id == client_id, models.Gasto.dia_id == dia_id
    )
    if para_atualizar:
        query = query.with_for_update()
    return query.first()


def somar_valores_do_dia(db: Session, dia_id: int) -> Decimal:
    """Soma dos gastos do dia lida no banco, nunca da coleção em memória.

    Leitura com bloqueio (`FOR UPDATE`, que o MySQL aceita em agregação):
    no REPEATABLE READ a leitura comum usa a foto do começo da transação e
    não veria um gasto gravado por outro pedido logo antes do bloqueio do dia.
    """
    total = (
        db.query(func.coalesce(func.sum(models.Gasto.valor), 0))
        .filter(models.Gasto.dia_id == dia_id)
        .with_for_update()
        .scalar()
    )
    return Decimal(total)



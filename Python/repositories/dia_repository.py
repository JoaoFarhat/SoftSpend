from decimal import Decimal
from sqlalchemy.orm import Session, joinedload
import models

def find_dia(db: Session, dia_id: int):
    return db.query(models.Dia).filter(models.Dia.id == dia_id).first()

def find_by_client_id(db: Session, client_id: str, ciclo_id: int):
    return (
        db.query(models.Dia)
        .filter(models.Dia.client_id == client_id, models.Dia.ciclo_id == ciclo_id)
        .first()
    )

def listar_dias_por_ciclo(db: Session, ciclo_id: int, skip: int, limit: int):
    return (
        db.query(models.Dia)
        .filter(models.Dia.ciclo_id == ciclo_id)
        .order_by(models.Dia.data)
        .offset(skip)
        .limit(limit)
        .options(joinedload(models.Dia.gastos))
        .all()
    )

def criar_dia(db: Session, dia: models.Dia):
    db.add(dia)
    db.flush()
    db.refresh(dia)
    return dia

def criar_dias_lote(db: Session, dias: list[models.Dia]):
    db.add_all(dias)
    db.flush()
    for dia in dias:
        db.refresh(dia)
    return dias

def incrementar_saldo(db: Session, dia_id: int, valor: Decimal):
    db.query(models.Dia).filter(models.Dia.id == dia_id).update(
        {models.Dia.saldo: models.Dia.saldo + valor},
        synchronize_session=False,
    )

def atualizar_dia(db: Session, dia: models.Dia):
    db.flush()
    db.refresh(dia)
    return dia

def remover_dia(db: Session, dia: models.Dia):
    db.delete(dia)

def remover_dias(db: Session, dias: list[models.Dia]):
    for dia in dias:
        db.delete(dia)
from sqlalchemy.orm import Session, joinedload
import models

def find_dia(db: Session, dia_id: int):
    return db.query(models.Dia).filter(models.Dia.id == dia_id).first()

def criar_dia(db: Session, dia: models.Dia):
    db.add(dia)
    db.commit()
    db.refresh(dia)
    return dia

def criar_dias_lote(db: Session, dias: list[models.Dia]):
    db.add_all(dias)
    db.commit()
    for dia in dias:
        db.refresh(dia)
    return dias

def incrementar_saldo(db: Session, dia_id: int, valor: float):
    db.query(models.Dia).filter(models.Dia.id == dia_id).update(
        {models.Dia.saldo: models.Dia.saldo + valor},
        synchronize_session=False,
    )

def atualizar_dia(db: Session, dia: models.Dia):
    db.commit()
    db.refresh(dia)
    return dia

def remover_dia(db: Session, dia: models.Dia):
    db.delete(dia)
    db.commit()

def remover_dias(db: Session, dias: list[models.Dia]):
    for dia in dias:
        db.delete(dia)
    db.commit()
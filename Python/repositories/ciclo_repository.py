from sqlalchemy.orm import Session, selectinload
import models


def criar_ciclo(db: Session, ciclo: models.Ciclo):
    db.add(ciclo)
    db.commit()
    db.refresh(ciclo)
    return ciclo

def get_all_ciclos(db: Session, user_id: int):
    return (
        db.query(models.Ciclo)
        .options(
            selectinload(models.Ciclo.dias)
            .selectinload(models.Dia.gastos)
        )
        .filter(models.Ciclo.id_usuario == user_id)
        .all()
    )

def get_ciclos_resumo(db: Session, user_id: int):
    return (
        db.query(models.Ciclo)
        .filter(models.Ciclo.id_usuario == user_id)
        .order_by(models.Ciclo.id.desc())
        .all()
    )

def get_ciclo_by_id(db: Session, ciclo_id: int):
    return (
        db.query(models.Ciclo)
        .options(
            selectinload(models.Ciclo.dias)
            .selectinload(models.Dia.gastos)
        )
        .filter(models.Ciclo.id == ciclo_id)
        .first()
    )
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

def get_user_ciclo_by_id(db: Session, ciclo_id: int, user_id: int):
    return (
        db.query(models.Ciclo)
        .filter(models.Ciclo.id == ciclo_id, models.Ciclo.id_usuario == user_id)
        .first()
    )


def incrementar_gasto_total(db: Session, ciclo_id: int, valor: float):
    db.query(models.Ciclo).filter(models.Ciclo.id == ciclo_id).update(
        {models.Ciclo.gasto_total: models.Ciclo.gasto_total + valor},
        synchronize_session=False,
    )

def update_ciclo(db: Session, ciclo: models.Ciclo, ciclo_request):
    ciclo.titulo = ciclo_request.titulo
    ciclo.periodo = ciclo_request.periodo
    ciclo.diaria = ciclo_request.diaria
    ciclo.valor_total = ciclo_request.valor_total
    db.commit()
    db.refresh(ciclo)
    return ciclo

def delete_ciclo(db: Session, ciclo: models.Ciclo):
    db.delete(ciclo)
    db.commit()

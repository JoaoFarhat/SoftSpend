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

def find_by_client_id(db: Session, client_id: str, dia_id: int):
    return (
        db.query(models.Gasto)
        .filter(models.Gasto.client_id == client_id, models.Gasto.dia_id == dia_id)
        .first()
    )



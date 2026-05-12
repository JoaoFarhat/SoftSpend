from sqlalchemy.orm import Session, joinedload
import models

def criar_gasto(db: Session, gasto: models.Gasto):
    db.add(gasto)
    return gasto

def remover_gasto(db: Session, gasto: models.Gasto):
    db.delete(gasto)
    return gasto

def find_gasto(db: Session, gasto_id: int):
    return db.query(models.Gasto).filter(models.Gasto.id == gasto_id).first()



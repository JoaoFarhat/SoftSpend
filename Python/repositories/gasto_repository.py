from sqlalchemy.orm import Session, joinedload
import models

def criar_gasto(db: Session, gasto: models.Gasto):
    db.add(gasto)
    db.commit()
    return gasto

def remover_gasto(db: Session, gasto: models.Gasto):
    db.delete(gasto)
    db.commit()
    return gasto

def atualizar_gasto(db: Session, gasto: models.Gasto):
    db.commit()
    db.refresh(gasto)
    return gasto

def find_gasto(db: Session, gasto_id: int):
    return db.query(models.Gasto).filter(models.Gasto.id == gasto_id).first()



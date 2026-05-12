from sqlalchemy.orm import Session, joinedload
import models

def find_dia(db: Session, dia_id: int):
    return db.query(models.Dia).filter(models.Dia.id == dia_id).first()
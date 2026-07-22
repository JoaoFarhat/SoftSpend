from sqlalchemy.orm import Session
import models
from dtos.ciclo import CicloResponse, CicloRequest
from repositories import ciclo_repository
from fastapi import HTTPException


def montar_ciclo(ciclo: CicloRequest) -> models.Ciclo:
    return models.Ciclo(
        valor_total=ciclo.valor_total,
        titulo=ciclo.titulo,
        periodo=ciclo.periodo,
        diaria=ciclo.diaria,
        gasto_total=0,
    )


def criar_ciclo(db: Session, ciclo: CicloRequest, user_id: int):
    novo_ciclo = montar_ciclo(ciclo)
    novo_ciclo.id_usuario = user_id
    return ciclo_repository.criar_ciclo(db, novo_ciclo)
    

def get_all_ciclos(db: Session, user_id: int):
    return ciclo_repository.get_all_ciclos(db, user_id)


def get_ciclos_resumo(db: Session, user_id: int):
    return ciclo_repository.get_ciclos_resumo(db, user_id)


def get_ciclo_by_id(db: Session, ciclo_id: int):
    return ciclo_repository.get_ciclo_by_id(db, ciclo_id)


def get_user_ciclo_by_id(db: Session, ciclo_id: int, user_id: int):

    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo nao encontrado")
        
    return ciclo    

def delete_ciclo(db: Session, ciclo_id: int, user_id: int):
    ciclo = get_user_ciclo_by_id(db, ciclo_id, user_id)
    
    ciclo_repository.delete_ciclo(db, ciclo)

    return None


def update_ciclo(db: Session, ciclo_id: int, user_id: int, ciclo_request: CicloRequest):
    ciclo = get_user_ciclo_by_id(db, ciclo_id, user_id)
    
    return ciclo_repository.update_ciclo(db, ciclo, ciclo_request)



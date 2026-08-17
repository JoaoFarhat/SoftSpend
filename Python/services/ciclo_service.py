import models
from dtos.ciclo import CicloResponse, CicloRequest
from repositories import ciclo_repository
from fastapi import HTTPException


def montar_ciclo(ciclo: CicloRequest) -> models.Ciclo:
    return models.Ciclo(
        client_id=ciclo.client_id,
        valor_total=ciclo.valor_total,
        titulo=ciclo.titulo,
        periodo=ciclo.periodo,
        diaria=ciclo.diaria,
        gasto_total=0,
    )


def criar_ciclo(db: Session, ciclo: CicloRequest, user_id: str):
    if ciclo.client_id:
        existente = ciclo_repository.find_by_client_id(db, ciclo.client_id, user_id)
        if existente:
            return existente

    novo_ciclo = montar_ciclo(ciclo)
    novo_ciclo.id_usuario = user_id
    return ciclo_repository.criar_ciclo(db, novo_ciclo)


def get_all_ciclos(db: Session, user_id: str, skip: int = 0, limit: int = 100):
    return ciclo_repository.get_all_ciclos(db, user_id, skip=skip, limit=limit)


def get_ciclos_resumo(db: Session, user_id: str, skip: int = 0, limit: int = 1000):
    return ciclo_repository.get_ciclos_resumo(db, user_id, skip=skip, limit=limit)


def get_ciclo_by_id(db: Session, ciclo_id: int):
    return ciclo_repository.get_ciclo_by_id(db, ciclo_id)


def get_user_ciclo_by_id(db: Session, ciclo_id: int, user_id: str):
    return ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)


def incrementar_gasto_total(db: Session, ciclo_id: int, valor: float):
    return ciclo_repository.incrementar_gasto_total(db, ciclo_id, valor)


def update_ciclo(db: Session, ciclo_id: int, user_id: str, ciclo_request: CicloRequest):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)
    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")
    return ciclo_repository.update_ciclo(db, ciclo, ciclo_request)


def delete_ciclo(db: Session, ciclo_id: int, user_id: str):
    ciclo = ciclo_repository.get_ciclo_by_id(db, ciclo_id)
    if not ciclo or ciclo.id_usuario != user_id:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")
    return ciclo_repository.delete_ciclo(db, ciclo)

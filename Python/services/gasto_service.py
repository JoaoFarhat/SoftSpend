from fastapi import HTTPException
from sqlalchemy.orm import Session
import models, dtos
from dtos.gasto import GastoRequest
from repositories import gasto_repository, dia_repository

def criar_gasto(db: Session, dia_id: int, gasto: GastoRequest, user_id: int):
    dia = dia_repository.find_dia(db, dia_id)

    if not dia:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    if dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    novo_gasto = models.Gasto(
        titulo=gasto.titulo,
        valor=gasto.valor,
        categoria=gasto.categoria,
        dia_id=dia_id
    )

    gasto_repository.criar_gasto(db, novo_gasto)
    dia.saldo -= gasto.valor
    dia.ciclo.gasto_total += gasto.valor
    db.commit()
    db.refresh(novo_gasto)

    return novo_gasto

def remover_gasto(db: Session, gasto_id: int, user_id: int):
    gasto = gasto_repository.find_gasto(db, gasto_id)

    if not gasto:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    if gasto.dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    dia = gasto.dia
    ciclo = dia.ciclo

    dia.saldo += gasto.valor
    ciclo.gasto_total -= gasto.valor

    gasto_repository.remover_gasto(db, gasto)
    db.commit()

    return None




    
from fastapi import HTTPException
from sqlalchemy.orm import Session
import models, dtos
from dtos.gasto import GastoRequest
from repositories import gasto_repository, dia_repository, ciclo_repository

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

    dia_repository.incrementar_saldo(db, dia.id, -gasto.valor)
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, gasto.valor)

    return gasto_repository.criar_gasto(db, novo_gasto)

def atualizar_gasto(db: Session, gasto_id: int, gasto_request: GastoRequest, user_id: int):
    gasto = gasto_repository.find_gasto(db, gasto_id)

    if not gasto:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    if gasto.dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    dia_atual = gasto.dia
    novo_dia_id = gasto_request.dia_id
    diferenca = gasto_request.valor - gasto.valor

    if novo_dia_id is not None and novo_dia_id != dia_atual.id:
        novo_dia = dia_repository.find_dia(db, novo_dia_id)

        if not novo_dia:
            raise HTTPException(status_code=404, detail="Dia não encontrado")

        if novo_dia.ciclo.id_usuario != user_id:
            raise HTTPException(status_code=403, detail="Acesso negado")

        if novo_dia.ciclo_id != dia_atual.ciclo_id:
            raise HTTPException(status_code=400, detail="O gasto só pode ser movido dentro do mesmo ciclo")

        # Restaura o saldo do dia antigo e decrementa o saldo do dia novo
        dia_repository.incrementar_saldo(db, dia_atual.id, gasto.valor)
        dia_repository.incrementar_saldo(db, novo_dia_id, -gasto_request.valor)
        ciclo_repository.incrementar_gasto_total(db, dia_atual.ciclo_id, diferenca)

        gasto.dia_id = novo_dia_id
        gasto.dia = novo_dia
    else:
        dia_repository.incrementar_saldo(db, dia_atual.id, -diferenca)
        ciclo_repository.incrementar_gasto_total(db, dia_atual.ciclo_id, diferenca)

    gasto.titulo = gasto_request.titulo
    gasto.valor = gasto_request.valor
    gasto.categoria = gasto_request.categoria

    gasto_repository.atualizar_gasto(db, gasto)

    return gasto


def remover_gasto(db: Session, gasto_id: int, user_id: int):
    gasto = gasto_repository.find_gasto(db, gasto_id)

    if not gasto:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    if gasto.dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    dia = gasto.dia

    dia_repository.incrementar_saldo(db, dia.id, gasto.valor)
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, -gasto.valor)

    gasto_repository.remover_gasto(db, gasto)

    return None




    
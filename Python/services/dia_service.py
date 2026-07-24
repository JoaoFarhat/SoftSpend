from fastapi import HTTPException
from sqlalchemy.orm import Session
from typing import List
import models
from dtos.dia import DiaRequest
from repositories import dia_repository, ciclo_repository


def criar_dia(db: Session, ciclo_id: int, dia: DiaRequest, user_id: int):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    novo_dia = models.Dia(
        data=dia.data,
        saldo=ciclo.diaria,
        ciclo_id=ciclo_id
    )

    return dia_repository.criar_dia(db, novo_dia)


def criar_dias_lote(db: Session, ciclo_id: int, dias: List[DiaRequest], user_id: int):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    novos_dias = [
        models.Dia(data=dia.data, saldo=ciclo.diaria, ciclo_id=ciclo_id)
        for dia in dias
    ]

    return dia_repository.criar_dias_lote(db, novos_dias)


def atualizar_dia(db: Session, dia_id: int, dia_request: DiaRequest, user_id: int):
    dia = dia_repository.find_dia(db, dia_id)

    if not dia:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    if dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    dia.data = dia_request.data

    return dia_repository.atualizar_dia(db, dia)


def sincronizar_dias_lote(db: Session, ciclo_id: int, dias: List[DiaRequest], user_id: int):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    novas_datas = {dia.data.date() for dia in dias}
    dias_existentes = list(ciclo.dias)
    datas_existentes = {dia_existente.data.date() for dia_existente in dias_existentes}

    dias_para_remover = [
        dia_existente for dia_existente in dias_existentes
        if dia_existente.data.date() not in novas_datas
    ]

    if dias_para_remover:
        gasto_total_removido = sum(
            gasto.valor for dia_existente in dias_para_remover for gasto in dia_existente.gastos
        )
        if gasto_total_removido:
            ciclo_repository.incrementar_gasto_total(db, ciclo_id, -gasto_total_removido)

        dia_repository.remover_dias(db, dias_para_remover)

    novos_dias = [
        models.Dia(data=dia.data, saldo=ciclo.diaria, ciclo_id=ciclo_id)
        for dia in dias
        if dia.data.date() not in datas_existentes
    ]

    if novos_dias:
        dia_repository.criar_dias_lote(db, novos_dias)

    db.refresh(ciclo)
    return ciclo.dias


def remover_dia(db: Session, dia_id: int, user_id: int):
    dia = dia_repository.find_dia(db, dia_id)

    if not dia:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    if dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    gasto_total_dia = sum(gasto.valor for gasto in dia.gastos)
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, -gasto_total_dia)

    dia_repository.remover_dia(db, dia)

    return None

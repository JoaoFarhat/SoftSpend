from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from typing import List
import models
from dtos.dia import DiaRequest
from repositories import dia_repository, ciclo_repository, gasto_repository


def listar_dias_por_ciclo(db: Session, ciclo_id: int, user_id: str, skip: int, limit: int):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    return dia_repository.listar_dias_por_ciclo(db, ciclo_id, skip, limit)


def criar_dia(db: Session, ciclo_id: int, dia: DiaRequest, user_id: str):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    if dia.client_id:
        existente = dia_repository.find_by_client_id(db, dia.client_id, ciclo_id)
        if existente:
            return existente

    novo_dia = models.Dia(
        client_id=dia.client_id,
        data=dia.data,
        saldo=ciclo.diaria,
        ciclo_id=ciclo_id
    )

    try:
        # Reenvio concorrente esbarra no unique `uix_dia_client_id_ciclo`:
        # desfaz só o savepoint e devolve o dia do primeiro pedido.
        with db.begin_nested():
            return dia_repository.criar_dia(db, novo_dia)
    except IntegrityError:
        existente = (
            dia_repository.find_by_client_id(
                db, dia.client_id, ciclo_id, para_atualizar=True
            )
            if dia.client_id
            else None
        )
        if existente is None:
            raise
        return existente


def criar_dias_lote(db: Session, ciclo_id: int, dias: List[DiaRequest], user_id: str):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    dias_existentes = {d.client_id: d for d in ciclo.dias if d.client_id}
    novos_dias: List[models.Dia] = []

    for dia in dias:
        if dia.client_id and dia.client_id in dias_existentes:
            novos_dias.append(dias_existentes[dia.client_id])
            continue
        novos_dias.append(models.Dia(client_id=dia.client_id, data=dia.data, saldo=ciclo.diaria, ciclo_id=ciclo_id))

    if novos_dias:
        try:
            # Reenvio concorrente esbarra no unique `uix_dia_client_id_ciclo`:
            # desfaz só o savepoint e devolve, na ordem pedida, os dias que o
            # primeiro pedido gravou (mesmo molde do `criar_dia`).
            with db.begin_nested():
                return dia_repository.criar_dias_lote(db, novos_dias)
        except IntegrityError:
            lidos = [
                dia_repository.find_by_client_id(
                    db, dia.client_id, ciclo_id, para_atualizar=True
                )
                if dia.client_id
                else None
                for dia in dias
            ]
            if any(lido is None for lido in lidos):
                raise
            return lidos

    return ciclo.dias


def remover_dia(db: Session, dia_id: int, user_id: str):
    # Com bloqueio: um gasto lançado neste dia por outro pedido espera o fim
    # deste delete, em vez de entrar entre a soma e o delete (sairia pelo
    # cascade sem nunca ter sido tirado do `gasto_total` da viagem).
    dia = dia_repository.find_dia(db, dia_id, para_atualizar=True)

    if not dia:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    if dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    # A soma vem do banco, não de `dia.gastos`: a coleção pode ter sido
    # carregada antes de outro pedido gravar um gasto aqui.
    gasto_total_dia = gasto_repository.somar_valores_do_dia(db, dia.id)
    # Recarrega a coleção no delete, para o cascade levar o gasto novo junto.
    db.expire(dia, ["gastos"])
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, -gasto_total_dia)
    # O UPDATE vai direto ao banco e nao toca o objeto em sessao; sem expirar,
    # um ciclo que continue vivo (o delete mexe em `ciclo.dias`) entregaria o
    # `gasto_total` velho para leituras posteriores na mesma sessao.
    db.expire(dia.ciclo, ["gasto_total"])

    dia_repository.remover_dia(db, dia)

    return None

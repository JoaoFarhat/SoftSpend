from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from typing import List
import models
from dtos.dia import DiaRequest
from repositories import dia_repository, ciclo_repository, gasto_repository
from services.dia_calendario import dia_de_calendario


def _data_dia_do_pedido(dia: DiaRequest):
    # App novo manda `data_local` (data de calendário); app antigo manda só o
    # instante e cai na mesma heurística do backfill (docs/data-do-dia.md §4).
    if dia.data_local is not None:
        return dia.data_local
    return dia_de_calendario(dia.data)


def listar_dias_por_ciclo(db: Session, ciclo_id: int, user_id: str, skip: int, limit: int):
    ciclo = ciclo_repository.get_user_ciclo_by_id(db, ciclo_id, user_id)

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    return dia_repository.listar_dias_por_ciclo(db, ciclo_id, skip, limit)


def criar_dia(db: Session, ciclo_id: int, dia: DiaRequest, user_id: str):
    # Trava a linha do ciclo: o saldo do dia novo nasce da `diaria` lida aqui,
    # e uma edição concorrente só ajusta os dias com UPDATE relativo — sem a
    # trava, um dia criado no mesmo instante ficaria com a diária antiga e
    # fora do ajuste.
    ciclo = ciclo_repository.get_user_ciclo_by_id(
        db, ciclo_id, user_id, para_atualizar=True
    )

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    if dia.client_id:
        existente = dia_repository.find_by_client_id(db, dia.client_id, ciclo_id)
        if existente:
            return existente

    novo_dia = models.Dia(
        client_id=dia.client_id,
        data=dia.data,
        data_dia=_data_dia_do_pedido(dia),
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
    # Mesma trava do `criar_dia`: a `diaria` lida aqui é o saldo dos dias
    # novos e precisa estar serializada com a edição do ciclo.
    ciclo = ciclo_repository.get_user_ciclo_by_id(
        db, ciclo_id, user_id, para_atualizar=True
    )

    if not ciclo:
        raise HTTPException(status_code=404, detail="Ciclo não encontrado")

    # `dias_existentes` também recebe os dias montados neste pedido: um
    # `client_id` repetido no mesmo corpo reusa o mesmo objeto (senão os dois
    # esbarram no unique `uix_dia_client_id_ciclo` na gravação e o lote vira
    # 500). A resposta mantém a ordem pedida, com o dia nas duas posições.
    dias_existentes = {d.client_id: d for d in ciclo.dias if d.client_id}
    novos_dias: List[models.Dia] = []

    for dia in dias:
        if dia.client_id and dia.client_id in dias_existentes:
            novos_dias.append(dias_existentes[dia.client_id])
            continue
        novo = models.Dia(client_id=dia.client_id, data=dia.data, data_dia=_data_dia_do_pedido(dia), saldo=ciclo.diaria, ciclo_id=ciclo_id)
        novos_dias.append(novo)
        if dia.client_id:
            dias_existentes[dia.client_id] = novo

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


def travar_dia_do_usuario(db: Session, dia_id: int, user_id: str) -> models.Dia:
    """Trava ciclo → dia, na ordem do servidor; 404 se o dia não é do usuário.

    Lê o dia sem trava só para saber o ciclo e o dono, trava o ciclo e então
    o dia (ver `dia_repository.find_dia`). Se o dia sumiu entre as duas
    leituras (outro pedido o apagou), responde 404.
    """
    dia = dia_repository.find_dia(db, dia_id)

    if not dia or dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    ciclo_repository.get_user_ciclo_by_id(
        db, dia.ciclo_id, user_id, para_atualizar=True, carregar_viagem=False
    )
    dia = dia_repository.find_dia(db, dia_id, para_atualizar=True)

    if not dia:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    return dia


def remover_dia(db: Session, dia_id: int, user_id: str):
    # Trava o ciclo e o dia: dois DELETE ao mesmo tempo (o app repete quando
    # perde a resposta) descontariam o total da viagem duas vezes; com a trava
    # o segundo espera e, com o dia já apagado, recebe 404.
    dia = travar_dia_do_usuario(db, dia_id, user_id)

    # Soma e apaga a partir da tabela, com bloqueio, e não de `dia.gastos`: um
    # gasto gravado por outro pedido depois da foto da transação ficaria fora
    # da soma (total errado para sempre) e sobraria no banco.
    gastos = gasto_repository.listar_por_dia_para_atualizar(db, dia.id)
    gasto_total_dia = sum((gasto.valor for gasto in gastos), Decimal("0"))
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, -gasto_total_dia)
    # O UPDATE vai direto ao banco e nao toca o objeto em sessao; sem expirar,
    # um ciclo que continue vivo (o delete mexe em `ciclo.dias`) entregaria o
    # `gasto_total` velho para leituras posteriores na mesma sessao.
    db.expire(dia.ciclo, ["gasto_total"])

    # Um a um pelo ORM, para a limpeza dos comprovantes (`after_delete`) e a
    # cascata do vínculo com a fatura valerem também para o gasto novo.
    for gasto in gastos:
        gasto_repository.remover_gasto(db, gasto)
    dia_repository.remover_dia(db, dia)

    return None

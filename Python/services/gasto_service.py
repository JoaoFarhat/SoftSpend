from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
import models, dtos
from dtos.gasto import GastoRequest
from repositories import gasto_repository, dia_repository, ciclo_repository
from services import dia_service, open_finance_reconciliation_service, storage_service
from services.comprovante_cleanup import (
    marcar_comprovante_para_remover,
    marcar_comprovante_para_remover_no_rollback,
)

# Teto da coluna `ciclos.gasto_total` (Numeric(10, 2)): um gasto que levasse o
# total da viagem além dele fazia o MySQL recusar o UPDATE do
# `incrementar_gasto_total` e a rota caía com 500, que o app repete sem fim.
TOTAL_MAXIMO_VIAGEM = Decimal("99999999.99")


def _checar_teto_total_viagem(db: Session, ciclo: models.Ciclo, incremento: Decimal):
    """422 se `gasto_total + incremento` não couber no Numeric(10, 2) da coluna.

    O ciclo já chega travado (SELECT FOR UPDATE) pelos caminhos que chamam —
    `travar_dia_do_usuario` e `_travar_gasto` —, então o `gasto_total` relido
    aqui não pode mudar até o commit. Remover gasto nunca passa por aqui:
    total menor sempre cabe.
    """
    if incremento <= 0:
        return
    db.refresh(ciclo, ["gasto_total"])
    if (ciclo.gasto_total or Decimal("0")) + incremento > TOTAL_MAXIMO_VIAGEM:
        raise HTTPException(
            status_code=422, detail="total_da_viagem_acima_do_limite"
        )


def criar_gasto(db: Session, dia_id: int, gasto: GastoRequest, user_id: str):
    # Trava ciclo → dia: um DELETE do mesmo dia ao mesmo tempo espera este
    # gasto entrar (e o desconta) ou já o apagou (404 aqui).
    dia = dia_service.travar_dia_do_usuario(db, dia_id, user_id)

    if gasto.client_id:
        existente = gasto_repository.find_by_client_id(db, gasto.client_id, dia_id)
        if existente:
            open_finance_reconciliation_service.conciliar_gasto(
                db, existente, user_id
            )
            return existente

    _checar_teto_total_viagem(db, dia.ciclo, gasto.valor)

    novo_gasto = models.Gasto(
        client_id=gasto.client_id,
        titulo=gasto.titulo,
        valor=gasto.valor,
        categoria=gasto.categoria,
        dia_id=dia_id
    )

    try:
        # Insert e incrementos no mesmo savepoint: um reenvio concorrente que
        # esbarre no unique `uix_gasto_client_id_dia` desfaz os três juntos e
        # o dinheiro não é contado duas vezes.
        with db.begin_nested():
            novo_gasto = gasto_repository.criar_gasto(db, novo_gasto)
            dia_repository.incrementar_saldo(db, dia.id, -gasto.valor)
            ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, gasto.valor)
            # UPDATE direto no banco não toca o objeto em sessão; sem expirar,
            # um ciclo vivo na sessão entregaria o gasto_total velho depois.
            db.expire(dia.ciclo, ["gasto_total"])
    except IntegrityError:
        existente = (
            gasto_repository.find_by_client_id(
                db, gasto.client_id, dia_id, para_atualizar=True
            )
            if gasto.client_id
            else None
        )
        if existente is None:
            raise
        open_finance_reconciliation_service.conciliar_gasto(db, existente, user_id)
        return existente

    open_finance_reconciliation_service.conciliar_gasto(db, novo_gasto, user_id)
    return novo_gasto

def _travar_gasto(db: Session, gasto_id: int, user_id: str, novo_dia_id: int | None = None):
    """Trava na ordem do resto do servidor: ciclo → dia(s) por id → gasto.

    O `remover_dia` trava ciclo, dia e depois os gastos dele, e o
    `PUT /ciclos` trava o ciclo e depois todos os dias; travar em outra ordem
    fazia dois pedidos ao mesmo tempo travarem um ao outro (deadlock, 500).
    Por isso o gasto é lido sem trava só para saber o dia e o ciclo; o dono
    e, ao mover, o dia novo (existe, é do usuário, é do mesmo ciclo) são
    conferidos antes de travar qualquer coisa. Então trava o ciclo, os dias
    envolvidos (o atual e, ao mover, o novo) em ordem crescente de id e só
    então o gasto. Se o gasto mudou de dia entre a leitura e a trava, refaz
    uma vez (com o ciclo já travado, a segunda volta não cruza com ninguém);
    mudando de novo, 409.

    Devolve `(gasto, dias)`, com `dias` = {id: Dia ou None} dos dias travados.
    """
    ciclo_travado = None
    for _ in range(2):
        gasto = gasto_repository.find_gasto(db, gasto_id)

        if not gasto:
            raise HTTPException(status_code=404, detail="Gasto não encontrado")

        if gasto.dia.ciclo.id_usuario != user_id:
            raise HTTPException(status_code=404, detail="Gasto não encontrado")

        dia_id = gasto.dia_id
        ciclo_id = gasto.dia.ciclo_id

        if novo_dia_id is not None and novo_dia_id != dia_id:
            novo_dia = dia_repository.find_dia(db, novo_dia_id)

            if not novo_dia or novo_dia.ciclo.id_usuario != user_id:
                raise HTTPException(status_code=404, detail="Dia não encontrado")

            if novo_dia.ciclo_id != ciclo_id:
                raise HTTPException(
                    status_code=400,
                    detail="O gasto só pode ser movido dentro do mesmo ciclo",
                )

        if ciclo_travado != ciclo_id:
            ciclo_repository.get_user_ciclo_by_id(
                db, ciclo_id, user_id, para_atualizar=True, carregar_viagem=False
            )
            ciclo_travado = ciclo_id

        ids = sorted({dia_id} | ({novo_dia_id} if novo_dia_id is not None else set()))
        dias = {
            id_: dia_repository.find_dia(db, id_, para_atualizar=True) for id_ in ids
        }

        gasto = gasto_repository.find_gasto_for_update(db, gasto_id)

        if not gasto:
            raise HTTPException(status_code=404, detail="Gasto não encontrado")

        if gasto.dia_id == dia_id:
            return gasto, dias

    raise HTTPException(
        status_code=409, detail="Gasto alterado ao mesmo tempo, tente de novo"
    )


def atualizar_gasto(db: Session, gasto_id: int, gasto_request: GastoRequest, user_id: str):
    gasto, dias = _travar_gasto(db, gasto_id, user_id, gasto_request.dia_id)

    dia_atual = dias[gasto.dia_id]
    novo_dia_id = gasto_request.dia_id
    diferenca = gasto_request.valor - gasto.valor

    # Mesmo teto do `criar_gasto`: subir o valor (em qualquer dia da viagem,
    # que é sempre o mesmo ciclo) não pode estourar o `gasto_total`.
    _checar_teto_total_viagem(db, dia_atual.ciclo, diferenca)

    if novo_dia_id is not None and novo_dia_id != dia_atual.id:
        # Conferido e travado em `_travar_gasto` (mesma trava do
        # `criar_gasto`): o gasto não entra num dia que outro pedido está
        # apagando. Se o dia sumiu entre a conferência e a trava, 404.
        novo_dia = dias[novo_dia_id]

        if not novo_dia:
            raise HTTPException(status_code=404, detail="Dia não encontrado")

        dia_repository.incrementar_saldo(db, dia_atual.id, gasto.valor)
        dia_repository.incrementar_saldo(db, novo_dia_id, -gasto_request.valor)
        ciclo_repository.incrementar_gasto_total(db, dia_atual.ciclo_id, diferenca)

        gasto.dia_id = novo_dia_id
        gasto.dia = novo_dia
    else:
        dia_repository.incrementar_saldo(db, dia_atual.id, -diferenca)
        ciclo_repository.incrementar_gasto_total(db, dia_atual.ciclo_id, diferenca)
    # UPDATE direto no banco não toca o objeto em sessão; sem expirar, um ciclo
    # vivo na sessão entregaria o gasto_total velho para leituras posteriores.
    db.expire(dia_atual.ciclo, ["gasto_total"])

    gasto.titulo = gasto_request.titulo
    gasto.valor = gasto_request.valor
    gasto.categoria = gasto_request.categoria

    gasto_repository.atualizar_gasto(db, gasto)
    open_finance_reconciliation_service.conciliar_gasto(db, gasto, user_id)

    return gasto


def remover_gasto(db: Session, gasto_id: int, user_id: str):
    gasto, dias = _travar_gasto(db, gasto_id, user_id)

    dia = dias[gasto.dia_id]

    dia_repository.incrementar_saldo(db, dia.id, gasto.valor)
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, -gasto.valor)
    # Mesmo motivo do remover_dia: UPDATE direto no banco não toca o objeto
    # em sessão; sem expirar, um ciclo vivo entregaria o gasto_total velho.
    db.expire(dia.ciclo, ["gasto_total"])

    gasto_repository.remover_gasto(db, gasto)

    return None


def _buscar_gasto_do_usuario(db: Session, gasto_id: int, user_id: str) -> models.Gasto:
    # Só a conferência de dono, sem trava: nos caminhos de comprovante a
    # linha não pode ficar presa durante o upload ao bucket (a parte lenta).
    # A `comprovante_key` é relida com trava em `_travar_gasto_comprovante`.
    gasto = gasto_repository.find_gasto(db, gasto_id)

    if not gasto:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    if gasto.dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    return gasto


def _travar_gasto_comprovante(db: Session, gasto_id: int) -> models.Gasto:
    """Relê o gasto com trava para usar a `comprovante_key` atual.

    Só a linha do gasto é travada: anexar/remover nota não faz UPDATE de
    saldo nem de total, então a trava não cruza a ordem ciclo → dia → gasto
    do resto do servidor. Sem a releitura (REPEATABLE READ mostra a foto
    antiga), dois uploads ao mesmo tempo marcavam a mesma key para apagar e
    a nota do primeiro ficava órfã no bucket, sem dono e sem limpeza.
    """
    gasto = gasto_repository.find_gasto_for_update(db, gasto_id)

    if not gasto:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    return gasto


def anexar_comprovante(db: Session, gasto_id: int, conteudo: bytes, content_type: str, user_id: str):
    """Sobe a nota fiscal e vincula ao gasto, substituindo a anterior se existir."""
    if not storage_service.esta_configurado():
        raise HTTPException(status_code=503, detail="Armazenamento de comprovantes indisponível")

    _buscar_gasto_do_usuario(db, gasto_id, user_id)

    nova_key = storage_service.salvar_comprovante(user_id, gasto_id, conteudo, content_type)
    marcar_comprovante_para_remover_no_rollback(db, nova_key)

    # Se o gasto sumiu entre o upload e a trava, o 404 leva ao rollback e o
    # listener de comprovante_cleanup apaga a nota nova do bucket.
    gasto = _travar_gasto_comprovante(db, gasto_id)

    key_anterior = gasto.comprovante_key
    gasto.comprovante_key = nova_key
    gasto_repository.atualizar_gasto(db, gasto)

    # Não remove o arquivo antigo imediatamente: se o commit falhar, o banco
    # continuaria apontando para uma key deletada. A remoção real acontece no
    # listener after_commit de comprovante_cleanup.
    marcar_comprovante_para_remover(db, key_anterior)

    return gasto


def remover_comprovante(db: Session, gasto_id: int, user_id: str):
    _buscar_gasto_do_usuario(db, gasto_id, user_id)
    gasto = _travar_gasto_comprovante(db, gasto_id)
    key = gasto.comprovante_key

    if key:
        gasto.comprovante_key = None
        gasto_repository.atualizar_gasto(db, gasto)
        marcar_comprovante_para_remover(db, key)

    return gasto




    
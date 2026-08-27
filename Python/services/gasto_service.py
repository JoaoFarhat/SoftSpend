from fastapi import HTTPException
from sqlalchemy.orm import Session
import models, dtos
from dtos.gasto import GastoRequest
from repositories import gasto_repository, dia_repository, ciclo_repository
from services import storage_service
from services.comprovante_cleanup import marcar_comprovante_para_remover

def criar_gasto(db: Session, dia_id: int, gasto: GastoRequest, user_id: str):
    dia = dia_repository.find_dia(db, dia_id)

    if not dia:
        raise HTTPException(status_code=404, detail="Dia não encontrado")

    if dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    if gasto.client_id:
        existente = gasto_repository.find_by_client_id(db, gasto.client_id, dia_id)
        if existente:
            return existente

    novo_gasto = models.Gasto(
        client_id=gasto.client_id,
        titulo=gasto.titulo,
        valor=gasto.valor,
        categoria=gasto.categoria,
        dia_id=dia_id
    )

    dia_repository.incrementar_saldo(db, dia.id, -gasto.valor)
    ciclo_repository.incrementar_gasto_total(db, dia.ciclo_id, gasto.valor)

    return gasto_repository.criar_gasto(db, novo_gasto)

def atualizar_gasto(db: Session, gasto_id: int, gasto_request: GastoRequest, user_id: str):
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


def remover_gasto(db: Session, gasto_id: int, user_id: str):
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


def _buscar_gasto_do_usuario(db: Session, gasto_id: int, user_id: str) -> models.Gasto:
    gasto = gasto_repository.find_gasto(db, gasto_id)

    if not gasto:
        raise HTTPException(status_code=404, detail="Gasto não encontrado")

    if gasto.dia.ciclo.id_usuario != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado")

    return gasto


def anexar_comprovante(db: Session, gasto_id: int, conteudo: bytes, content_type: str, user_id: str):
    """Sobe a nota fiscal e vincula ao gasto, substituindo a anterior se existir."""
    if not storage_service.esta_configurado():
        raise HTTPException(status_code=503, detail="Armazenamento de comprovantes indisponível")

    gasto = _buscar_gasto_do_usuario(db, gasto_id, user_id)
    key_anterior = gasto.comprovante_key

    gasto.comprovante_key = storage_service.salvar_comprovante(user_id, gasto_id, conteudo, content_type)
    gasto_repository.atualizar_gasto(db, gasto)

    # Não remove o arquivo antigo imediatamente: se o commit falhar, o banco
    # continuaria apontando para uma key deletada. A remoção real acontece no
    # listener after_commit de comprovante_cleanup.
    marcar_comprovante_para_remover(db, key_anterior)

    return gasto


def remover_comprovante(db: Session, gasto_id: int, user_id: str):
    gasto = _buscar_gasto_do_usuario(db, gasto_id, user_id)
    key = gasto.comprovante_key

    if key:
        gasto.comprovante_key = None
        gasto_repository.atualizar_gasto(db, gasto)
        marcar_comprovante_para_remover(db, key)

    return gasto




    
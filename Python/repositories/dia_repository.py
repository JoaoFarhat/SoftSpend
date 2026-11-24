from decimal import Decimal
from sqlalchemy.orm import Session, joinedload
import models

def find_dia(db: Session, dia_id: int, para_atualizar: bool = False):
    # `para_atualizar` bloqueia a linha do dia (SELECT ... FOR UPDATE): apagar
    # o dia, lançar um gasto nele ou mover um gasto para ele ficam em fila, e
    # um segundo DELETE do mesmo dia espera o primeiro e recebe 404. Só o dia
    # é travado; o ciclo segue só com o UPDATE relativo do `gasto_total` (dia
    # antes do ciclo, sem deadlock com o `PUT /ciclos`).
    query = db.query(models.Dia).filter(models.Dia.id == dia_id)
    if para_atualizar:
        query = query.with_for_update()
    return query.first()

def find_by_client_id(db: Session, client_id: str, ciclo_id: int, para_atualizar: bool = False):
    # `para_atualizar`: leitura com bloqueio, que vê a linha recém-gravada por
    # outro pedido mesmo em REPEATABLE READ (ver `ciclo_repository`).
    query = db.query(models.Dia).filter(
        models.Dia.client_id == client_id, models.Dia.ciclo_id == ciclo_id
    )
    if para_atualizar:
        query = query.with_for_update()
    return query.first()

def listar_dias_por_ciclo(db: Session, ciclo_id: int, skip: int, limit: int):
    return (
        db.query(models.Dia)
        .filter(models.Dia.ciclo_id == ciclo_id)
        .order_by(models.Dia.data, models.Dia.id)
        .offset(skip)
        .limit(limit)
        .options(joinedload(models.Dia.gastos))
        .all()
    )

def criar_dia(db: Session, dia: models.Dia):
    db.add(dia)
    db.flush()
    db.refresh(dia)
    return dia

def criar_dias_lote(db: Session, dias: list[models.Dia]):
    db.add_all(dias)
    db.flush()
    for dia in dias:
        db.refresh(dia)
    return dias

def incrementar_saldo(db: Session, dia_id: int, valor: Decimal):
    # "fetch" re-le o dia no banco depois do UPDATE: sem isso, um objeto que
    # continue vivo na sessao guardaria o saldo velho e o entregaria para
    # leituras posteriores na mesma sessao.
    db.query(models.Dia).filter(models.Dia.id == dia_id).update(
        {models.Dia.saldo: models.Dia.saldo + valor},
        synchronize_session="fetch",
    )

def remover_dia(db: Session, dia: models.Dia):
    db.delete(dia)
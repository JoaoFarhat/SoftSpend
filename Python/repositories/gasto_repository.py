from sqlalchemy.orm import Session, joinedload
import models

def criar_gasto(db: Session, gasto: models.Gasto):
    db.add(gasto)
    db.flush()
    return gasto

def remover_gasto(db: Session, gasto: models.Gasto):
    db.delete(gasto)

def atualizar_gasto(db: Session, gasto: models.Gasto):
    db.flush()
    db.refresh(gasto)
    return gasto

def find_gasto(db: Session, gasto_id: int):
    return db.query(models.Gasto).filter(models.Gasto.id == gasto_id).first()


def find_gasto_for_update(db: Session, gasto_id: int):
    # `populate_existing`: o gasto costuma já estar na sessão (lido sem trava
    # pelo `gasto_service._travar_gasto`); sem isso o ORM manteria os campos
    # da primeira leitura e não veria o `dia_id` que outro pedido mudou.
    return (
        db.query(models.Gasto)
        .filter(models.Gasto.id == gasto_id)
        .with_for_update()
        .populate_existing()
        .first()
    )


def listar_por_dia_para_atualizar(db: Session, dia_id: int):
    # Leitura com bloqueio direto da tabela, não pela relação `dia.gastos`: no
    # MySQL (REPEATABLE READ) a leitura comum usa a foto do começo da
    # transação e não vê o gasto que outro pedido gravou depois. O
    # `populate_existing` traz o valor atual mesmo de gasto já na sessão.
    return (
        db.query(models.Gasto)
        .filter(models.Gasto.dia_id == dia_id)
        .with_for_update()
        .populate_existing()
        .all()
    )


def find_by_client_id(db: Session, client_id: str, dia_id: int, para_atualizar: bool = False):
    # `para_atualizar`: leitura com bloqueio, que vê a linha recém-gravada por
    # outro pedido mesmo em REPEATABLE READ (ver `ciclo_repository`).
    query = db.query(models.Gasto).filter(
        models.Gasto.client_id == client_id, models.Gasto.dia_id == dia_id
    )
    if para_atualizar:
        query = query.with_for_update()
    return query.first()



from decimal import Decimal
from sqlalchemy.orm import Session, selectinload
import models


def criar_ciclo(db: Session, ciclo: models.Ciclo):
    db.add(ciclo)
    db.flush()
    db.refresh(ciclo)
    return ciclo

def get_all_ciclos(db: Session, user_id: str, skip: int = 0, limit: int = 100):
    return (
        db.query(models.Ciclo)
        .options(
            selectinload(models.Ciclo.dias)
            .selectinload(models.Dia.gastos)
            .selectinload(models.Gasto.open_finance_match)
            .selectinload(models.ExpenseTransactionMatch.transacao)
        )
        .filter(models.Ciclo.id_usuario == user_id)
        .offset(skip)
        .limit(limit)
        .all()
    )

def get_ciclos_resumo(db: Session, user_id: str, antes_de: int | None = None, skip: int = 0, limit: int = 1000):
    query = (
        db.query(models.Ciclo)
        .options(
            selectinload(models.Ciclo.dias)
            .selectinload(models.Dia.gastos)
            .selectinload(models.Gasto.open_finance_match)
            .selectinload(models.ExpenseTransactionMatch.transacao)
        )
        .filter(models.Ciclo.id_usuario == user_id)
    )
    if antes_de is not None:
        query = query.filter(models.Ciclo.id < antes_de)
    return (
        query.order_by(models.Ciclo.id.desc())
        .offset(skip)
        .limit(limit)
        .all()
    )

def get_ciclo_by_id(db: Session, ciclo_id: int):
    return (
        db.query(models.Ciclo)
        .options(
            selectinload(models.Ciclo.dias)
            .selectinload(models.Dia.gastos)
        )
        .filter(models.Ciclo.id == ciclo_id)
        .first()
    )

def get_user_ciclo_by_id(db: Session, ciclo_id: int, user_id: str):
    return (
        db.query(models.Ciclo)
        .options(
            selectinload(models.Ciclo.dias)
            .selectinload(models.Dia.gastos)
            .selectinload(models.Gasto.open_finance_match)
            .selectinload(models.ExpenseTransactionMatch.transacao)
        )
        .filter(models.Ciclo.id == ciclo_id, models.Ciclo.id_usuario == user_id)
        .first()
    )


def find_by_client_id(db: Session, client_id: str, user_id: str, para_atualizar: bool = False):
    # `para_atualizar` faz leitura com bloqueio (SELECT ... FOR UPDATE), que no
    # MySQL (REPEATABLE READ) enxerga a linha que outro pedido acabou de
    # gravar; a leitura comum devolveria a foto tirada no início da transação.
    query = db.query(models.Ciclo).filter(
        models.Ciclo.client_id == client_id, models.Ciclo.id_usuario == user_id
    )
    if para_atualizar:
        query = query.with_for_update()
    return query.first()


def incrementar_gasto_total(db: Session, ciclo_id: int, valor: Decimal):
    db.query(models.Ciclo).filter(models.Ciclo.id == ciclo_id).update(
        {models.Ciclo.gasto_total: models.Ciclo.gasto_total + valor},
        synchronize_session=False,
    )

def update_ciclo(db: Session, ciclo: models.Ciclo, ciclo_request):
    diaria_mudou = ciclo.diaria != ciclo_request.diaria
    ciclo.titulo = ciclo_request.titulo
    ciclo.periodo = ciclo_request.periodo
    ciclo.diaria = ciclo_request.diaria
    ciclo.valor_total = ciclo_request.valor_total
    if diaria_mudou:
        # O saldo do dia é a diária menos os gastos dele; diária nova sem
        # recalcular deixaria o relatório e o app com o saldo velho.
        for dia in ciclo.dias:
            dia.saldo = ciclo_request.diaria - sum(
                (gasto.valor or Decimal(0) for gasto in dia.gastos or []),
                Decimal(0),
            )
    db.flush()
    db.refresh(ciclo)
    return ciclo

def delete_ciclo(db: Session, ciclo: models.Ciclo):
    db.delete(ciclo)

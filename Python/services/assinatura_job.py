"""Conciliação diária das assinaturas com a Apple (`docs/assinatura.md` §2.7).

Rede de segurança para webhook perdido. Rodado pelo timer do systemd
(`deploy/ec2/softspend-assinaturas.timer`), sem rota pública:

    cd Python && .venv/bin/python -m services.assinatura_job

Para cada linha com `original_transaction_id` e status diferente de
`expired`/`revoked`, ou que expirou nos últimos 7 dias, consulta `Get All
Subscription Statuses` **no ambiente da linha** e chama `reconciliar`. Falha
de uma linha não derruba as outras; o log leva só contagens.

Saída: 0 = rodou sem falha, 1 = alguma linha falhou (as outras rodaram),
2 = Apple não configurada.
"""

from __future__ import annotations

import logging
import sys
import time
from datetime import datetime, timedelta

from sqlalchemy import and_, or_
from sqlalchemy.orm import Session

import models
from services import apple_service, assinatura_service

logger = logging.getLogger(__name__)

JANELA_EXPIRADAS = timedelta(days=7)
PAUSA_ENTRE_LINHAS = 0.2  # segundos; evita estourar a cota da Apple


def ids_para_conciliar(db: Session, agora: datetime) -> list[int]:
    finais = (assinatura_service.EXPIRED, assinatura_service.REVOKED)
    consulta = (
        db.query(models.Assinatura.id)
        .filter(models.Assinatura.original_transaction_id.isnot(None))
        .filter(
            or_(
                models.Assinatura.status.notin_(finais),
                and_(
                    models.Assinatura.expira_em.isnot(None),
                    models.Assinatura.expira_em >= agora - JANELA_EXPIRADAS,
                ),
            )
        )
        .order_by(models.Assinatura.id)
    )
    return [linha.id for linha in consulta]


def executar(
    db: Session,
    agora: datetime | None = None,
    pausa: float = PAUSA_ENTRE_LINHAS,
    dormir=time.sleep,
) -> dict:
    """Concilia as linhas e devolve as contagens.

    `AppleNaoConfigurada` sobe (o job inteiro não tem como rodar).
    """
    agora = agora or assinatura_service.agora_utc()
    ids = ids_para_conciliar(db, agora)
    contagem = {"total": len(ids), "reconciliadas": 0, "sem_estado": 0, "falhas": 0}
    clientes: dict[str, object] = {}

    for indice, assinatura_id in enumerate(ids):
        if indice and pausa:
            dormir(pausa)
        try:
            linha = db.get(models.Assinatura, assinatura_id)
            if linha is None or not linha.original_transaction_id:
                continue
            ambiente = linha.ambiente or apple_service.PRODUCTION
            if ambiente not in clientes:
                clientes[ambiente] = apple_service.obter_cliente_apple(ambiente)
            estado = clientes[ambiente].status(linha.original_transaction_id)
            if estado is None:
                contagem["sem_estado"] += 1
                continue
            assinatura_service.reconciliar(
                db, linha, estado.transacao, estado.renovacao, agora,
                status_apple=estado.status, ambiente=ambiente,
            )
            db.commit()
            contagem["reconciliadas"] += 1
        except apple_service.AppleNaoConfigurada:
            db.rollback()
            raise
        except Exception as exc:
            db.rollback()
            contagem["falhas"] += 1
            # Sem id nem valores: só o tipo do erro.
            logger.warning("Conciliação de uma assinatura falhou: %s", type(exc).__name__)

    logger.info(
        "Conciliação diária: %(total)d linhas, %(reconciliadas)d reconciliadas, "
        "%(sem_estado)d sem estado na Apple, %(falhas)d falhas",
        contagem,
    )
    return contagem


def main() -> int:
    from database import SessionLocal
    from logging_config import setup_logging

    setup_logging()
    if not apple_service.configurada():
        logger.error("Conciliação diária: Apple não configurada (APPLE_* ou certificados)")
        return 2
    db = SessionLocal()
    try:
        contagem = executar(db)
    except apple_service.AppleNaoConfigurada:
        logger.error("Conciliação diária: Apple não configurada")
        return 2
    finally:
        db.close()
    return 1 if contagem["falhas"] else 0


if __name__ == "__main__":
    sys.exit(main())

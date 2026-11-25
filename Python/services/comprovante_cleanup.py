import logging

from sqlalchemy import event
from sqlalchemy.orm import Session

import models
from services import storage_service

logger = logging.getLogger(__name__)

CHAVE_PENDENTES = "comprovantes_para_remover"
CHAVE_ROLLBACK = "comprovantes_para_remover_no_rollback"


def marcar_comprovante_para_remover(session: Session, key: str | None) -> None:
    """Marca uma key de comprovante para remoção do storage após o commit.

    Use isto em atualizações/replace de comprovantes, em vez de remover o
    arquivo do S3 antes de confirmar a transação. Se ocorrer rollback, a key
    é descartada sem deletar o arquivo.
    """
    if not key:
        return
    session.info.setdefault(CHAVE_PENDENTES, []).append(key)


def marcar_comprovante_para_remover_no_rollback(session: Session, key: str) -> None:
    session.info.setdefault(CHAVE_ROLLBACK, []).append(key)


@event.listens_for(models.Gasto, "after_delete")
def _anotar_comprovante_removido(mapper, connection, target):
    if not target.comprovante_key:
        return

    session = Session.object_session(target)

    if session is None:
        return

    session.info.setdefault(CHAVE_PENDENTES, []).append(target.comprovante_key)


@event.listens_for(Session, "after_commit")
def _remover_comprovantes_pendentes(session):
    session.info.pop(CHAVE_ROLLBACK, None)
    keys = set(session.info.pop(CHAVE_PENDENTES, ()))
    if not keys:
        return

    # Uma chamada em lote: nota a nota, a exclusão de uma viagem ou da conta
    # com centenas de comprovantes passava dos 8 s de tempo limite do app.
    storage_service.remover_comprovantes(keys)
    logger.info("Processada remoção de %d comprovante(s) do storage", len(keys))


@event.listens_for(Session, "after_rollback")
def _descartar_comprovantes_pendentes(session):
    session.info.pop(CHAVE_PENDENTES, None)
    keys = set(session.info.pop(CHAVE_ROLLBACK, ()))
    if not keys:
        return

    storage_service.remover_comprovantes(keys)
    logger.info("Processada remoção de %d comprovante(s) após rollback", len(keys))

import logging

from sqlalchemy import event
from sqlalchemy.orm import Session

import models
from services import storage_service

logger = logging.getLogger(__name__)

CHAVE_PENDENTES = "comprovantes_para_remover"


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
    keys = session.info.pop(CHAVE_PENDENTES, None)

    if not keys:
        return

    for key in keys:
        storage_service.remover_comprovante(key)

    logger.info("Removidos %d comprovante(s) do storage", len(keys))


@event.listens_for(Session, "after_rollback")
def _descartar_comprovantes_pendentes(session):
    session.info.pop(CHAVE_PENDENTES, None)

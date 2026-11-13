import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user_id
from dtos.assinatura import AssinaturaResponse, TransacaoRequest
from limiter import limiter
from services import apple_service, assinatura_service

logger = logging.getLogger(__name__)

router = APIRouter(tags=["assinatura"])

MSG_INVALIDO = "Comprovante da compra inválido."
MSG_OUTRA_CONTA = "Esta assinatura pertence a outra conta do SoftSpend."
MSG_APPLE_FORA = "Tente de novo em instantes."
MSG_NAO_CONFIGURADA = "Assinatura indisponível no momento."


@router.get("/api/assinatura", response_model=AssinaturaResponse)
@limiter.limit("60/minute")
def obter_assinatura(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """Estado da assinatura e o `app_account_token` para a compra no StoreKit.

    A primeira chamada cria a linha com o token; as seguintes devolvem o mesmo.
    """
    return assinatura_service.estado(db, user_id)


@router.post("/api/assinatura/transacoes", response_model=AssinaturaResponse)
@limiter.limit("20/minute")
def registrar_transacao(
    request: Request,
    corpo: TransacaoRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """Recebe a `jwsRepresentation` do StoreKit 2 (`docs/assinatura.md` §2.3)."""
    try:
        return assinatura_service.registrar_transacao(db, user_id, corpo.jws)
    except apple_service.AppleNaoConfigurada:
        db.rollback()
        logger.error("POST /api/assinatura/transacoes sem configuração da Apple")
        raise HTTPException(status_code=503, detail=MSG_NAO_CONFIGURADA)
    except apple_service.ComprovanteInvalido as exc:
        db.rollback()
        logger.info("Transação recusada: %s", exc)
        raise HTTPException(status_code=400, detail=MSG_INVALIDO)
    except assinatura_service.AssinaturaDeOutraConta:
        db.rollback()
        logger.info("Transação de outra conta recusada")
        raise HTTPException(status_code=409, detail=MSG_OUTRA_CONTA)
    except apple_service.AppleIndisponivel:
        db.rollback()
        logger.warning("Apple indisponível em /transacoes")
        raise HTTPException(status_code=503, detail=MSG_APPLE_FORA)


def _processar(db: Session, signed_payload: str) -> JSONResponse:
    try:
        resultado = assinatura_service.processar_notificacao(db, signed_payload)
    except apple_service.AppleNaoConfigurada:
        db.rollback()
        logger.error("Webhook da Apple sem configuração")
        return JSONResponse(status_code=503, content={"error": MSG_NAO_CONFIGURADA})
    except apple_service.ComprovanteInvalido as exc:
        db.rollback()
        logger.warning("Webhook da Apple com assinatura inválida: %s", exc)
        return JSONResponse(status_code=400, content={"error": MSG_INVALIDO})
    except Exception:
        # A Apple repete; o notificationUUID não ficou gravado.
        db.rollback()
        logger.exception("Webhook da Apple falhou ao reconciliar")
        return JSONResponse(status_code=500, content={"error": "Erro interno."})
    logger.info("Webhook da Apple: %s", resultado)
    return JSONResponse(status_code=200, content={"ok": True})


@router.post("/api/webhooks/apple", include_in_schema=False)
@limiter.limit("300/minute")
async def webhook_apple(request: Request, db: Session = Depends(get_db)):
    """App Store Server Notifications V2.

    Sempre registrada, sem login: a única autenticação é a assinatura do
    `signedPayload`, verificada com a cadeia da Apple.
    """
    try:
        corpo = await request.json()
    except ValueError:
        corpo = None
    signed_payload = corpo.get("signedPayload") if isinstance(corpo, dict) else None
    if not isinstance(signed_payload, str) or not signed_payload:
        return JSONResponse(status_code=400, content={"error": MSG_INVALIDO})
    return await run_in_threadpool(_processar, db, signed_payload)

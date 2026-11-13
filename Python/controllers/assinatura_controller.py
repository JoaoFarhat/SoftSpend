from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user_id
from dtos.assinatura import AssinaturaResponse
from limiter import limiter
from services import assinatura_service

router = APIRouter(tags=["assinatura"])


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

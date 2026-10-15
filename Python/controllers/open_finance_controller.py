import hmac
import logging
import os
from typing import Any

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Body,
    Depends,
    Header,
    HTTPException,
    Request,
)
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from database import get_db
from dependencies import get_current_user_id
from dtos.open_finance import (
    CreditCardAccountResponse,
    CreditCardBillDetailResponse,
    CreditCardBillResponse,
    CreditCardTransactionResponse,
    ExpenseTransactionMatchResponse,
    ImportacaoOpenFinanceResponse,
    OpenFinanceConnectionResponse,
)
from limiter import limiter
from repositories import open_finance_repository
from services import open_finance_service
from services.open_finance_service import PluggyRequestError

logger = logging.getLogger(__name__)
router = APIRouter(tags=["open-finance"])


class PluggyConnectTokenRequest(BaseModel):
    item_id: str | None = Field(default=None, alias="itemId", min_length=1)
    oauth_redirect_uri: str | None = Field(
        default=None, alias="oauthRedirectUri", min_length=1
    )
    avoid_duplicates: bool = Field(default=True, alias="avoidDuplicates")

    model_config = ConfigDict(populate_by_name=True)


class PluggyConnectTokenResponse(BaseModel):
    accessToken: str


class PluggyWebhookEvent(BaseModel):
    event: str
    eventId: str | None = None

    model_config = ConfigDict(extra="allow")


def _resposta_pluggy(exc: PluggyRequestError) -> HTTPException:
    status_code = exc.status_code
    if status_code == 429:
        status_code = 502
    if status_code >= 500 and status_code != 503:
        status_code = 502
    return HTTPException(status_code=status_code, detail=exc.detail)


@router.post("/api/connect-token", response_model=PluggyConnectTokenResponse)
@limiter.limit("30/minute")
async def create_connect_token(
    request: Request,
    payload: PluggyConnectTokenRequest | None = Body(default=None),
    user_id: str = Depends(get_current_user_id),
):
    payload = payload or PluggyConnectTokenRequest()
    try:
        access_token = await open_finance_service.criar_connect_token(
            client_user_id=user_id,
            item_id=payload.item_id,
            oauth_redirect_uri=payload.oauth_redirect_uri,
            avoid_duplicates=payload.avoid_duplicates,
        )
    except PluggyRequestError as exc:
        raise _resposta_pluggy(exc)

    return PluggyConnectTokenResponse(accessToken=access_token)


@router.post(
    "/api/open-finance/items/{item_id}/sync",
    response_model=ImportacaoOpenFinanceResponse,
)
@limiter.limit("5/minute")
async def sincronizar_item(
    request: Request,
    item_id: str,
    user_id: str = Depends(get_current_user_id),
) -> ImportacaoOpenFinanceResponse:
    try:
        resultado = await open_finance_service.sincronizar_item(
            item_id, expected_user_id=user_id
        )
    except PluggyRequestError as exc:
        raise _resposta_pluggy(exc)
    except ValueError as exc:
        raise HTTPException(status_code=403, detail=str(exc))

    return ImportacaoOpenFinanceResponse(**resultado)


@router.get(
    "/api/open-finance/connections",
    response_model=list[OpenFinanceConnectionResponse],
)
@limiter.limit("60/minute")
def listar_conexoes(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    return open_finance_repository.listar_conexoes(db, user_id)


@router.get(
    "/api/open-finance/cards", response_model=list[CreditCardAccountResponse]
)
@limiter.limit("60/minute")
def listar_cartoes(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    return open_finance_repository.listar_cartoes(db, user_id)


@router.get(
    "/api/open-finance/cards/{cartao_id}/bills",
    response_model=list[CreditCardBillResponse],
)
@limiter.limit("60/minute")
def listar_faturas(
    request: Request,
    cartao_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    cartao = open_finance_repository.buscar_cartao(db, user_id, cartao_id)
    if not cartao:
        raise HTTPException(status_code=404, detail="Cartão não encontrado")
    return open_finance_repository.listar_faturas(db, user_id, cartao_id)


@router.get(
    "/api/open-finance/bills/{fatura_id}",
    response_model=CreditCardBillDetailResponse,
)
@limiter.limit("60/minute")
def detalhar_fatura(
    request: Request,
    fatura_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    fatura = open_finance_repository.buscar_fatura(db, user_id, fatura_id)
    if not fatura:
        raise HTTPException(status_code=404, detail="Fatura não encontrada")
    fatura.transacoes = open_finance_repository.listar_transacoes_fatura(
        db, user_id, fatura_id
    )
    return fatura


@router.get(
    "/api/open-finance/cards/{cartao_id}/transactions",
    response_model=list[CreditCardTransactionResponse],
)
@limiter.limit("60/minute")
def listar_transacoes(
    request: Request,
    cartao_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    cartao = open_finance_repository.buscar_cartao(db, user_id, cartao_id)
    if not cartao:
        raise HTTPException(status_code=404, detail="Cartão não encontrado")
    return open_finance_repository.listar_transacoes(db, user_id, cartao_id)


@router.get(
    "/api/open-finance/matches",
    response_model=list[ExpenseTransactionMatchResponse],
)
@limiter.limit("60/minute")
def listar_matches(
    request: Request,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    return open_finance_repository.listar_matches_usuario(db, user_id)


@router.post(
    "/api/open-finance/matches/{match_id}/confirm",
    response_model=ExpenseTransactionMatchResponse,
)
@limiter.limit("30/minute")
def confirmar_match(
    request: Request,
    match_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    match = open_finance_repository.buscar_match(db, user_id, match_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match não encontrado")
    return open_finance_repository.confirmar_match(db, match)


@router.delete(
    "/api/open-finance/matches/{match_id}",
    response_model=ExpenseTransactionMatchResponse,
)
@limiter.limit("30/minute")
def remover_match(
    request: Request,
    match_id: int,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    match = open_finance_repository.buscar_match(db, user_id, match_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match não encontrado")
    response = ExpenseTransactionMatchResponse.model_validate(match)
    open_finance_repository.remover_match(db, match)
    return response


def _validar_webhook(
    request: Request,
    x_pluggy_webhook_secret: str | None,
) -> None:
    expected = os.getenv("PLUGGY_WEBHOOK_SECRET")
    if not expected:
        logger.error("PLUGGY_WEBHOOK_SECRET não configurado")
        raise HTTPException(
            status_code=503, detail="Webhook do Pluggy não configurado"
        )

    recebido = x_pluggy_webhook_secret or request.query_params.get("token")
    if not recebido or not hmac.compare_digest(recebido, expected):
        raise HTTPException(status_code=401, detail="Webhook não autorizado")


@router.post("/api/webhooks/pluggy", status_code=200)
@limiter.limit("120/minute")
async def handle_pluggy_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_pluggy_webhook_secret: str | None = Header(default=None),
):
    _validar_webhook(request, x_pluggy_webhook_secret)

    corpo = await request.body()
    if not corpo:
        return {"received": True, "ignored": "empty_body"}

    try:
        evento = PluggyWebhookEvent.model_validate_json(corpo)
    except ValueError:
        return {"received": True, "ignored": "invalid_payload"}

    evento_dict: dict[str, Any] = evento.model_dump()
    background_tasks.add_task(open_finance_service.processar_evento, evento_dict)
    return {"received": True}

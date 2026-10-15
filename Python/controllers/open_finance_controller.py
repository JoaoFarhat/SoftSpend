import hmac
import logging
import os
from json import JSONDecodeError
from typing import Any, Optional

from fastapi import APIRouter, BackgroundTasks, Body, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from dependencies import get_current_user_id
from limiter import limiter
from services import open_finance_service

logger = logging.getLogger(__name__)
router = APIRouter(tags=["open-finance"])


class ConnectTokenRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    item_id: Optional[str] = Field(default=None, alias="itemId", min_length=1, max_length=100)
    oauth_redirect_uri: Optional[str] = Field(
        default=None,
        alias="oauthRedirectUri",
        min_length=1,
        max_length=500,
    )
    avoid_duplicates: bool = Field(default=True, alias="avoidDuplicates")


class ConnectTokenResponse(BaseModel):
    accessToken: str


class PluggyWebhookEvent(BaseModel):
    model_config = ConfigDict(extra="allow", populate_by_name=True)

    event: str = Field(..., min_length=1, max_length=100)
    event_id: str = Field(..., alias="eventId", min_length=1, max_length=100)
    item_id: Optional[str] = Field(default=None, alias="itemId", max_length=100)
    client_user_id: Optional[str] = Field(default=None, alias="clientUserId", max_length=100)
    triggered_by: Optional[str] = Field(default=None, alias="triggeredBy", max_length=50)
    connector_id: Optional[int] = Field(default=None, alias="connectorId")
    transaction_ids: Optional[list[str]] = Field(default=None, alias="transactionIds", max_length=1000)
    created_transactions_link: Optional[str] = Field(
        default=None,
        alias="createdTransactionsLink",
        max_length=2000,
    )
    error: Optional[dict[str, Any]] = None


def _validar_webhook_secret(secret: Optional[str]):
    expected = os.getenv("PLUGGY_WEBHOOK_SECRET")
    if not expected:
        raise HTTPException(
            status_code=503,
            detail="Webhook do Pluggy não configurado",
        )

    if not secret or not hmac.compare_digest(
        secret.encode("utf-8"), expected.encode("utf-8")
    ):
        raise HTTPException(status_code=401, detail="Webhook não autorizado")


@router.post("/api/connect-token", response_model=ConnectTokenResponse)
@limiter.limit("30/minute")
async def create_connect_token(
    request: Request,
    payload: Optional[ConnectTokenRequest] = Body(default=None),
    user_id: str = Depends(get_current_user_id),
):
    payload = payload or ConnectTokenRequest()
    access_token = await open_finance_service.criar_connect_token(
        client_user_id=user_id,
        item_id=payload.item_id,
        oauth_redirect_uri=payload.oauth_redirect_uri,
        avoid_duplicates=payload.avoid_duplicates,
    )
    return ConnectTokenResponse(accessToken=access_token)


@router.post("/api/webhooks/pluggy")
@limiter.limit("120/minute")
async def pluggy_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_pluggy_webhook_secret: Optional[str] = Header(
        default=None,
        alias="X-Pluggy-Webhook-Secret",
    ),
    token: Optional[str] = Query(default=None),
):
    _validar_webhook_secret(x_pluggy_webhook_secret or token)

    try:
        payload = await request.json()
    except JSONDecodeError:
        logger.info("Probe do Pluggy recebido sem corpo JSON")
        return {"received": True, "ignored": "empty_body"}

    try:
        evento = PluggyWebhookEvent.model_validate(payload)
    except ValidationError:
        logger.warning("Webhook Pluggy autenticado com payload não reconhecido")
        return {"received": True, "ignored": "unrecognized_payload"}

    background_tasks.add_task(
        open_finance_service.processar_evento,
        evento.model_dump(by_alias=True),
    )
    return {"received": True}

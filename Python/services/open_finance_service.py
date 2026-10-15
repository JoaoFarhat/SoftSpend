import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx
from fastapi import HTTPException

logger = logging.getLogger(__name__)

PLUGGY_API_URL = os.getenv("PLUGGY_API_URL", "https://api.pluggy.ai").rstrip("/")
PLUGGY_TIMEOUT_SECONDS = float(os.getenv("PLUGGY_TIMEOUT_SECONDS", "10"))
API_KEY_TTL = timedelta(hours=2)
API_KEY_REFRESH_MARGIN = timedelta(minutes=5)

_api_key: Optional[str] = None
_api_key_expira_em: Optional[datetime] = None
_api_key_lock = asyncio.Lock()


def _credenciais() -> tuple[str, str]:
    client_id = os.getenv("PLUGGY_CLIENT_ID")
    client_secret = os.getenv("PLUGGY_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise HTTPException(
            status_code=503,
            detail="Integração com Pluggy não configurada",
        )
    return client_id, client_secret


def _falha_pluggy(response: httpx.Response) -> HTTPException:
    logger.warning("Pluggy respondeu %s em %s", response.status_code, response.request.url.path)
    return HTTPException(
        status_code=502,
        detail="Falha ao comunicar com o provedor Open Finance",
    )


async def _obter_api_key(client: httpx.AsyncClient) -> str:
    global _api_key, _api_key_expira_em

    agora = datetime.now(timezone.utc)
    if _api_key and _api_key_expira_em and agora < _api_key_expira_em:
        return _api_key

    async with _api_key_lock:
        agora = datetime.now(timezone.utc)
        if _api_key and _api_key_expira_em and agora < _api_key_expira_em:
            return _api_key

        client_id, client_secret = _credenciais()
        try:
            response = await client.post(
                "/auth",
                json={"clientId": client_id, "clientSecret": client_secret},
            )
        except httpx.HTTPError:
            logger.exception("Falha de rede ao autenticar no Pluggy")
            raise HTTPException(
                status_code=502,
                detail="Falha ao comunicar com o provedor Open Finance",
            )

        if response.status_code != 200:
            raise _falha_pluggy(response)

        api_key = response.json().get("apiKey")
        if not api_key:
            logger.warning("Resposta de autenticação do Pluggy sem apiKey")
            raise HTTPException(
                status_code=502,
                detail="Resposta inválida do provedor Open Finance",
            )

        _api_key = api_key
        _api_key_expira_em = agora + API_KEY_TTL - API_KEY_REFRESH_MARGIN
        return api_key


async def criar_connect_token(
    client_user_id: str,
    item_id: Optional[str] = None,
    oauth_redirect_uri: Optional[str] = None,
    avoid_duplicates: bool = True,
) -> str:
    options = {
        "clientUserId": client_user_id,
        "avoidDuplicates": avoid_duplicates,
    }

    webhook_url = os.getenv("PLUGGY_WEBHOOK_URL")
    if webhook_url:
        options["webhookUrl"] = webhook_url
    if oauth_redirect_uri:
        options["oauthRedirectUri"] = oauth_redirect_uri

    body = {"options": options}
    if item_id:
        body["itemId"] = item_id

    async with httpx.AsyncClient(
        base_url=PLUGGY_API_URL,
        timeout=PLUGGY_TIMEOUT_SECONDS,
    ) as client:
        api_key = await _obter_api_key(client)
        try:
            response = await client.post(
                "/connect_token",
                headers={"X-API-KEY": api_key},
                json=body,
            )
        except httpx.HTTPError:
            logger.exception("Falha de rede ao criar connect token no Pluggy")
            raise HTTPException(
                status_code=502,
                detail="Falha ao comunicar com o provedor Open Finance",
            )

    if response.status_code != 200:
        raise _falha_pluggy(response)

    access_token = response.json().get("accessToken")
    if not access_token:
        logger.warning("Resposta de connect token do Pluggy sem accessToken")
        raise HTTPException(
            status_code=502,
            detail="Resposta inválida do provedor Open Finance",
        )
    return access_token


async def processar_evento(evento: dict):
    try:
        await _processar_evento(evento)
    except Exception:
        logger.exception(
            "Falha ao processar webhook Pluggy event=%s event_id=%s",
            evento.get("event"),
            evento.get("eventId"),
        )


async def _processar_evento(evento: dict):
    handlers = {
        "item/created": _handle_item_created,
        "item/updated": _handle_item_updated,
        "item/deleted": _handle_item_deleted,
        "item/error": _handle_item_error,
        "item/waiting_user_input": _handle_item_waiting_user_input,
        "item/waiting_user_action": _handle_item_waiting_user_action,
        "item/login_succeeded": _handle_item_login_succeeded,
        "transactions/created": _handle_transactions_created,
        "transactions/updated": _handle_transactions_updated,
        "transactions/deleted": _handle_transactions_deleted,
    }

    event_name = evento.get("event")
    handler = handlers.get(event_name)
    if handler:
        await handler(evento)
        return

    logger.info(
        "Evento Pluggy sem handler específico: event=%s event_id=%s",
        event_name,
        evento.get("eventId"),
    )


def _contexto_item(evento: dict) -> str:
    return (
        f"event_id={evento.get('eventId')} item_id={evento.get('itemId')} "
        f"client_user_id={evento.get('clientUserId')} triggered_by={evento.get('triggeredBy')}"
    )


async def _handle_item_created(evento: dict):
    logger.info("Item Pluggy criado: %s", _contexto_item(evento))


async def _handle_item_updated(evento: dict):
    logger.info("Item Pluggy atualizado: %s", _contexto_item(evento))


async def _handle_item_deleted(evento: dict):
    logger.info("Item Pluggy removido: %s", _contexto_item(evento))


async def _handle_item_error(evento: dict):
    logger.warning(
        "Erro no item Pluggy: %s error=%s",
        _contexto_item(evento),
        evento.get("error"),
    )


async def _handle_item_waiting_user_input(evento: dict):
    logger.info("Item Pluggy aguardando input do usuário: %s", _contexto_item(evento))


async def _handle_item_waiting_user_action(evento: dict):
    logger.info("Item Pluggy aguardando ação do usuário: %s", _contexto_item(evento))


async def _handle_item_login_succeeded(evento: dict):
    logger.info("Login do item Pluggy concluído: %s", _contexto_item(evento))


async def _handle_transactions_created(evento: dict):
    logger.info(
        "Transações Pluggy criadas: event_id=%s transaction_ids=%s link=%s",
        evento.get("eventId"),
        evento.get("transactionIds"),
        evento.get("createdTransactionsLink"),
    )


async def _handle_transactions_updated(evento: dict):
    logger.info(
        "Transações Pluggy atualizadas: event_id=%s transaction_ids=%s",
        evento.get("eventId"),
        evento.get("transactionIds"),
    )


async def _handle_transactions_deleted(evento: dict):
    logger.info(
        "Transações Pluggy removidas: event_id=%s transaction_ids=%s",
        evento.get("eventId"),
        evento.get("transactionIds"),
    )

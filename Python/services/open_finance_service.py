import asyncio
import logging
import os
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, InvalidOperation
from typing import Any
from urllib.parse import urlparse

import httpx
from fastapi.concurrency import run_in_threadpool

from database import SessionLocal
import models
from repositories import open_finance_repository
from services import open_finance_reconciliation_service

logger = logging.getLogger(__name__)

PLUGGY_API_URL = os.getenv("PLUGGY_API_URL", "https://api.pluggy.ai").rstrip("/")
PLUGGY_TIMEOUT_SECONDS = float(os.getenv("PLUGGY_TIMEOUT_SECONDS", "10"))
_API_KEY_TTL = timedelta(hours=2)
_API_KEY_REFRESH_MARGIN = timedelta(minutes=5)
_api_key_cache: dict[str, Any] = {"key": None, "expires_at": None}
_api_key_lock = asyncio.Lock()


class PluggyRequestError(Exception):
    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def _credenciais() -> tuple[str, str]:
    client_id = os.getenv("PLUGGY_CLIENT_ID")
    client_secret = os.getenv("PLUGGY_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise PluggyRequestError(503, "Integração com Pluggy não configurada")
    return client_id, client_secret


def _pluggy_configurado() -> bool:
    return bool(os.getenv("PLUGGY_CLIENT_ID") and os.getenv("PLUGGY_CLIENT_SECRET"))


def _erro_pluggy(response: httpx.Response) -> None:
    try:
        detail = response.json()
    except ValueError:
        detail = response.text[:500]

    logger.error(
        "Erro na API do Pluggy",
        extra={
            "status_code": response.status_code,
            "url": str(response.request.url),
            "detail": detail,
        },
    )
    raise PluggyRequestError(response.status_code, "Falha na API do Pluggy")


async def _obter_api_key(client: httpx.AsyncClient) -> str:
    now = datetime.now(timezone.utc)
    expires_at = _api_key_cache["expires_at"]
    if _api_key_cache["key"] and expires_at and now < expires_at:
        return _api_key_cache["key"]

    async with _api_key_lock:
        now = datetime.now(timezone.utc)
        expires_at = _api_key_cache["expires_at"]
        if _api_key_cache["key"] and expires_at and now < expires_at:
            return _api_key_cache["key"]

        client_id, client_secret = _credenciais()
        response = await client.post(
            "/auth",
            json={"clientId": client_id, "clientSecret": client_secret},
        )
        if response.status_code >= 400:
            _erro_pluggy(response)

        _api_key_cache["key"] = response.json()["apiKey"]
        _api_key_cache["expires_at"] = (
            now + _API_KEY_TTL - _API_KEY_REFRESH_MARGIN
        )
        return _api_key_cache["key"]


def _headers(api_key: str) -> dict[str, str]:
    return {
        "X-API-KEY": api_key,
        "Content-Type": "application/json",
    }


async def _get_json(
    client: httpx.AsyncClient,
    api_key: str,
    path: str,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    response = await client.get(path, params=params, headers=_headers(api_key))
    if response.status_code >= 400:
        _erro_pluggy(response)
    return response.json()


def _parse_datetime(value: Any) -> datetime | None:
    if value is None or isinstance(value, datetime):
        if isinstance(value, datetime) and value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value
    if isinstance(value, date):
        return datetime.combine(value, time.min, timezone.utc)
    if not isinstance(value, str):
        return None

    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            parsed = datetime.combine(
                date.fromisoformat(value), time.min, timezone.utc
            )
        except ValueError:
            return None

    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def _parse_decimal(value: Any) -> Decimal | None:
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _normalizar_account(account: dict[str, Any]) -> dict[str, Any]:
    account = dict(account)
    account["balance"] = _parse_decimal(account.get("balance"))
    credit_data = dict(account.get("creditData") or {})
    for campo in ("creditLimit", "availableCreditLimit", "minimumPayment"):
        credit_data[campo] = _parse_decimal(credit_data.get(campo))
    for campo in ("balanceCloseDate", "balanceDueDate"):
        credit_data[campo] = _parse_datetime(credit_data.get(campo))
    account["creditData"] = credit_data
    return account


def _normalizar_bill(bill: dict[str, Any]) -> dict[str, Any]:
    bill = dict(bill)
    bill["dueDate"] = _parse_datetime(bill.get("dueDate"))
    bill["billClosingDate"] = _parse_datetime(bill.get("billClosingDate"))
    bill["totalAmount"] = _parse_decimal(bill.get("totalAmount"))
    bill["minimumPaymentAmount"] = _parse_decimal(
        bill.get("minimumPaymentAmount")
    )
    return bill


def _normalizar_transaction(transaction: dict[str, Any]) -> dict[str, Any]:
    transaction = dict(transaction)
    transaction["date"] = _parse_datetime(transaction.get("date"))
    transaction["amount"] = _parse_decimal(transaction.get("amount"))
    transaction["amountInAccountCurrency"] = _parse_decimal(
        transaction.get("amountInAccountCurrency")
    )
    return transaction


async def criar_connect_token(
    client_user_id: str,
    item_id: str | None = None,
    oauth_redirect_uri: str | None = None,
    avoid_duplicates: bool = False,
) -> str:
    if not _pluggy_configurado():
        raise PluggyRequestError(503, "Credenciais do Pluggy não configuradas")

    options: dict[str, Any] = {"clientUserId": client_user_id}
    webhook_url = os.getenv("PLUGGY_WEBHOOK_URL")
    if webhook_url:
        options["webhookUrl"] = webhook_url
    if oauth_redirect_uri:
        options["oauthRedirectUri"] = str(oauth_redirect_uri)
    if avoid_duplicates:
        options["avoidDuplicates"] = True

    payload: dict[str, Any] = {"options": options}
    if item_id:
        payload["itemId"] = item_id

    try:
        async with httpx.AsyncClient(
            base_url=PLUGGY_API_URL,
            timeout=PLUGGY_TIMEOUT_SECONDS,
        ) as client:
            api_key = await _obter_api_key(client)
            response = await client.post(
                "/connect_token", json=payload, headers=_headers(api_key)
            )
            if response.status_code >= 400:
                _erro_pluggy(response)

            return response.json()["accessToken"]
    except httpx.TimeoutException as exc:
        raise PluggyRequestError(504, "Timeout ao chamar a API do Pluggy") from exc
    except httpx.RequestError as exc:
        raise PluggyRequestError(
            502, "Não foi possível conectar à API do Pluggy"
        ) from exc


async def _buscar_item(
    client: httpx.AsyncClient, api_key: str, item_id: str
) -> dict[str, Any]:
    return await _get_json(client, api_key, f"/items/{item_id}")


async def _listar_contas(
    client: httpx.AsyncClient, api_key: str, item_id: str
) -> list[dict[str, Any]]:
    contas: list[dict[str, Any]] = []
    page = 1
    total_pages = 1

    while page <= total_pages:
        data = await _get_json(
            client,
            api_key,
            "/accounts",
            params={
                "itemId": item_id,
                "type": "CREDIT",
                "page": page,
                "pageSize": 500,
            },
        )
        contas.extend(data.get("results") or [])
        total_pages = int(data.get("totalPages") or page)
        page += 1

    return contas


async def _listar_faturas(
    client: httpx.AsyncClient, api_key: str, account_id: str
) -> list[dict[str, Any]]:
    faturas: list[dict[str, Any]] = []
    page = 1
    total_pages = 1

    try:
        while page <= total_pages:
            data = await _get_json(
                client,
                api_key,
                "/bills",
                params={"accountId": account_id, "page": page, "pageSize": 500},
            )
            faturas.extend(data.get("results") or [])
            total_pages = int(data.get("totalPages") or page)
            page += 1
    except PluggyRequestError as exc:
        if exc.status_code not in {400, 403, 404, 422}:
            raise
        logger.warning(
            "Faturas não disponíveis para a conta Pluggy",
            extra={"account_id": account_id, "status_code": exc.status_code},
        )

    return faturas


def _path_do_cursor(next_cursor: str) -> str:
    if next_cursor.startswith("?"):
        return f"/v2/transactions{next_cursor}"

    parsed = urlparse(next_cursor)
    if parsed.scheme:
        pluggy_host = urlparse(PLUGGY_API_URL).netloc
        if parsed.netloc != pluggy_host:
            raise PluggyRequestError(502, "Cursor de transações inválido")
        path = parsed.path
        if parsed.query:
            path = f"{path}?{parsed.query}"
        return path

    if next_cursor.startswith("/"):
        return next_cursor
    return f"/v2/transactions?{next_cursor}"


async def _listar_transacoes(
    client: httpx.AsyncClient,
    api_key: str,
    account_id: str,
    created_at_from: str | None = None,
    transaction_ids: list[str] | None = None,
) -> list[dict[str, Any]]:
    params: dict[str, Any] = {"accountId": account_id}
    if created_at_from:
        params["createdAtFrom"] = created_at_from
    if transaction_ids:
        params["ids"] = ",".join(transaction_ids)

    path = "/v2/transactions"
    transacoes: list[dict[str, Any]] = []
    for _ in range(100):
        data = await _get_json(client, api_key, path, params=params)
        transacoes.extend(data.get("results") or [])
        next_cursor = data.get("next")
        if not next_cursor:
            return transacoes
        path = _path_do_cursor(next_cursor)
        params = None

    logger.warning(
        "Paginação de transações do Pluggy excedeu o limite de segurança",
        extra={"account_id": account_id},
    )
    return transacoes


def _persistir_importacao(dados: dict[str, Any]) -> dict[str, int | str]:
    item = dados["item"]
    item_id = dados["item_id"]
    agora = datetime.now(timezone.utc)
    db = SessionLocal()
    try:
        existente = open_finance_repository.buscar_conexao_por_item(db, item_id)
        user_id = (
            item.get("clientUserId")
            or dados.get("client_user_id")
            or (existente.user_id if existente else None)
        )
        if not user_id:
            raise ValueError("Item do Pluggy não possui usuário associado")

        connector = item.get("connector") or {}
        conexao = open_finance_repository.upsert_conexao(
            db,
            item_id=item_id,
            user_id=user_id,
            client_user_id=item.get("clientUserId") or dados.get("client_user_id"),
            institution_name=connector.get("name") or item.get("institution"),
            status=item.get("status"),
            error_code=(item.get("error") or {}).get("code"),
            error_message=(item.get("error") or {}).get("message"),
        )

        faturas_total = 0
        transacoes_total = 0
        for dados_cartao in dados["accounts"]:
            account = _normalizar_account(dados_cartao["account"])
            cartao = open_finance_repository.upsert_cartao(db, conexao, account)
            faturas = {}

            for bill_data in dados_cartao["bills"]:
                if not bill_data.get("id"):
                    continue
                bill = _normalizar_bill(bill_data)
                fatura = open_finance_repository.upsert_fatura(db, cartao, bill)
                faturas[fatura.bill_id] = fatura
                faturas_total += 1

            for transaction_data in dados_cartao["transactions"]:
                if not transaction_data.get("id"):
                    continue
                transaction = _normalizar_transaction(transaction_data)
                metadata = transaction.get("creditCardMetadata") or {}
                provider_bill_id = metadata.get("billId")
                fatura = faturas.get(provider_bill_id)
                if provider_bill_id and fatura is None:
                    fatura = open_finance_repository.buscar_fatura_por_provider_id(
                        db, provider_bill_id
                    )
                    if fatura and fatura.cartao_id != cartao.id:
                        fatura = None
                open_finance_repository.upsert_transacao(
                    db, cartao, transaction, fatura=fatura, last_seen_at=agora
                )
                transacoes_total += 1

        conciliacoes = open_finance_reconciliation_service.conciliar_usuario(
            db, conexao.user_id
        )
        conexao.last_sync_at = agora
        conexao.error_code = None
        conexao.error_message = None
        db.commit()
        return {
            "item_id": item_id,
            "cartoes": len(dados["accounts"]),
            "faturas": faturas_total,
            "transacoes": transacoes_total,
            "conciliacoes": conciliacoes,
        }
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def _buscar_user_id_conexao(item_id: str) -> str | None:
    db = SessionLocal()
    try:
        conexao = open_finance_repository.buscar_conexao_por_item(db, item_id)
        return conexao.user_id if conexao else None
    finally:
        db.close()


async def sincronizar_item(
    item_id: str,
    expected_user_id: str | None = None,
    event_client_user_id: str | None = None,
) -> dict[str, int | str]:
    if not _pluggy_configurado():
        raise PluggyRequestError(503, "Credenciais do Pluggy não configuradas")

    try:
        async with httpx.AsyncClient(
            base_url=PLUGGY_API_URL,
            timeout=PLUGGY_TIMEOUT_SECONDS,
        ) as client:
            api_key = await _obter_api_key(client)
            item = await _buscar_item(client, api_key, item_id)
            client_user_id = item.get("clientUserId")
            if expected_user_id:
                if client_user_id and client_user_id != expected_user_id:
                    raise PluggyRequestError(
                        403, "Item do Pluggy não pertence ao usuário autenticado"
                    )
                if not client_user_id:
                    owner_id = await run_in_threadpool(
                        _buscar_user_id_conexao, item_id
                    )
                    if owner_id != expected_user_id:
                        raise PluggyRequestError(
                            403,
                            "Item do Pluggy não pertence ao usuário autenticado",
                        )

            contas = await _listar_contas(client, api_key, item_id)
            cartoes = [
                conta
                for conta in contas
                if conta.get("type") == "CREDIT"
                and conta.get("subtype") == "CREDIT_CARD"
            ]

            accounts = []
            for cartao in cartoes:
                account_id = cartao.get("id")
                if not account_id:
                    continue
                faturas = await _listar_faturas(client, api_key, account_id)
                transacoes = await _listar_transacoes(client, api_key, account_id)
                accounts.append(
                    {
                        "account": cartao,
                        "bills": faturas,
                        "transactions": transacoes,
                    }
                )
    except httpx.TimeoutException as exc:
        raise PluggyRequestError(504, "Timeout ao chamar a API do Pluggy") from exc
    except httpx.RequestError as exc:
        raise PluggyRequestError(
            502, "Não foi possível conectar à API do Pluggy"
        ) from exc

    return await run_in_threadpool(
        _persistir_importacao,
        {
            "item_id": item_id,
            "item": item,
            "accounts": accounts,
            "client_user_id": event_client_user_id,
        },
    )


def _atualizar_status_item(
    item_id: str,
    status: str,
    error_code: str | None = None,
    error_message: str | None = None,
) -> None:
    db = SessionLocal()
    try:
        conexao = open_finance_repository.buscar_conexao_por_item(db, item_id)
        if conexao:
            conexao.status = status
            conexao.error_code = error_code
            conexao.error_message = error_message
            db.commit()
    finally:
        db.close()


def _remover_transacoes(item_id: str, account_id: str, transaction_ids: list[str]) -> None:
    db = SessionLocal()
    try:
        conexao = open_finance_repository.buscar_conexao_por_item(db, item_id)
        if not conexao:
            return
        cartao = (
            db.query(models.CreditCardAccount)
            .filter(
                models.CreditCardAccount.account_id == account_id,
                models.CreditCardAccount.conexao_id == conexao.id,
            )
            .first()
        )
        if not cartao:
            return
        open_finance_repository.remover_transacoes(
            db, conexao.user_id, cartao.id, transaction_ids
        )
        db.commit()
    finally:
        db.close()


async def _sincronizar_item_com_log(
    item_id: str | None, event_client_user_id: str | None = None
) -> None:
    if not item_id:
        return
    try:
        await sincronizar_item(
            item_id, event_client_user_id=event_client_user_id
        )
    except Exception as exc:
        logger.exception(
            "Falha ao sincronizar item do Pluggy",
            extra={"item_id": item_id, "error": str(exc)},
        )
        await run_in_threadpool(
            _atualizar_status_item, item_id, "ERROR", "SYNC_ERROR", str(exc)[:500]
        )


async def _handle_item_created(evento: dict[str, Any]) -> None:
    await _sincronizar_item_com_log(
        evento.get("itemId"), evento.get("clientUserId")
    )


async def _handle_item_updated(evento: dict[str, Any]) -> None:
    await _sincronizar_item_com_log(
        evento.get("itemId"), evento.get("clientUserId")
    )


async def _handle_item_deleted(evento: dict[str, Any]) -> None:
    item_id = evento.get("itemId")
    if item_id:
        await run_in_threadpool(_atualizar_status_item, item_id, "DELETED")


async def _handle_item_error(evento: dict[str, Any]) -> None:
    item_id = evento.get("itemId")
    error = evento.get("error") or {}
    if item_id:
        await run_in_threadpool(
            _atualizar_status_item,
            item_id,
            "ERROR",
            error.get("code"),
            error.get("message"),
        )


async def _handle_item_waiting_user_input(evento: dict[str, Any]) -> None:
    item_id = evento.get("itemId")
    if item_id:
        await run_in_threadpool(
            _atualizar_status_item, item_id, "WAITING_USER_INPUT"
        )


async def _handle_item_waiting_user_action(evento: dict[str, Any]) -> None:
    item_id = evento.get("itemId")
    if item_id:
        await run_in_threadpool(
            _atualizar_status_item, item_id, "WAITING_USER_ACTION"
        )


async def _handle_item_login_succeeded(evento: dict[str, Any]) -> None:
    item_id = evento.get("itemId")
    if item_id:
        await run_in_threadpool(_atualizar_status_item, item_id, "UPDATING")


async def _handle_transactions_created(evento: dict[str, Any]) -> None:
    await _sincronizar_item_com_log(evento.get("itemId"))


async def _handle_transactions_updated(evento: dict[str, Any]) -> None:
    await _sincronizar_item_com_log(evento.get("itemId"))


async def _handle_transactions_deleted(evento: dict[str, Any]) -> None:
    item_id = evento.get("itemId")
    account_id = evento.get("accountId")
    transaction_ids = evento.get("transactionIds") or []
    if item_id and account_id and transaction_ids:
        await run_in_threadpool(
            _remover_transacoes, item_id, account_id, transaction_ids
        )


_EVENT_HANDLERS = {
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


async def processar_evento(evento: dict[str, Any]) -> None:
    event_name = evento.get("event")
    handler = _EVENT_HANDLERS.get(event_name)
    if handler is None:
        logger.info(
            "Evento Pluggy ignorado",
            extra={"event": event_name, "event_id": evento.get("eventId")},
        )
        return

    try:
        await handler(evento)
    except Exception:
        logger.exception(
            "Falha ao processar evento Pluggy",
            extra={
                "event": event_name,
                "event_id": evento.get("eventId"),
                "item_id": evento.get("itemId"),
            },
        )

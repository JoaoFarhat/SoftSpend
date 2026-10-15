import ipaddress
from unittest.mock import patch

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session
from starlette.requests import Request

import limiter
from dtos.gasto.gasto_request import GastoRequest
from enums.categoria_enum import Categoria
from middlewares import REQUEST_ID_PATTERN
from services.comprovante_cleanup import (
    marcar_comprovante_para_remover,
    marcar_comprovante_para_remover_no_rollback,
)


def _request(client: str, forwarded: str | None = None) -> Request:
    headers = []
    if forwarded:
        headers.append((b"x-forwarded-for", forwarded.encode()))
    return Request({"type": "http", "client": (client, 1234), "headers": headers})


def test_forwarded_ip_requires_trusted_peer(monkeypatch):
    monkeypatch.setattr(limiter, "TRUST_PROXY", True)
    monkeypatch.setattr(
        limiter,
        "TRUSTED_PROXY_IPS",
        (ipaddress.ip_network("127.0.0.1"), ipaddress.ip_network("10.0.0.0/8")),
    )

    assert limiter.get_real_ip(_request("127.0.0.1", "198.51.100.7, 10.0.0.8")) == "198.51.100.7"
    assert limiter.get_real_ip(_request("203.0.113.9", "198.51.100.7")) == "203.0.113.9"
    assert limiter.get_real_ip(_request("127.0.0.1", "invalid-value")) == "127.0.0.1"


def test_request_id_accepts_only_bounded_safe_characters():
    assert REQUEST_ID_PATTERN.fullmatch("ios.123_test-id")
    assert not REQUEST_ID_PATTERN.fullmatch("x" * 129)
    assert not REQUEST_ID_PATTERN.fullmatch("bad\nlog")


def test_monetary_limits_are_enforced_after_rounding():
    valid = GastoRequest(titulo="Teste", valor="99999999.99", categoria=Categoria.ALIMENTACAO)
    assert str(valid.valor) == "99999999.99"

    try:
        GastoRequest(titulo="Teste", valor="9999999999.99", categoria=Categoria.ALIMENTACAO)
    except ValueError:
        pass
    else:
        raise AssertionError("Valor acima de DECIMAL(10, 2) deveria ser rejeitado")


def test_receipt_cleanup_follows_transaction_outcome():
    engine = create_engine("sqlite://")

    with patch("services.comprovante_cleanup.storage_service.remover_comprovante") as remover:
        session = Session(engine)
        session.execute(text("SELECT 1"))
        marcar_comprovante_para_remover(session, "old-key")
        marcar_comprovante_para_remover_no_rollback(session, "new-key")
        session.rollback()
        remover.assert_called_once_with("new-key")

    with patch("services.comprovante_cleanup.storage_service.remover_comprovante") as remover:
        session = Session(engine)
        session.execute(text("SELECT 1"))
        marcar_comprovante_para_remover(session, "old-key")
        marcar_comprovante_para_remover_no_rollback(session, "new-key")
        session.commit()
        remover.assert_called_once_with("old-key")


def test_refresh_token_rotation_reuse_detection_and_logout(monkeypatch):
    import importlib
    import sys

    monkeypatch.setenv("SECRET_KEY", "access-token-secret-with-at-least-32-characters")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY",
        "different-refresh-secret-with-at-least-32-characters",
    )

    sys.modules.pop("services.auth_service", None)
    auth_service = importlib.import_module("services.auth_service")

    from database import Base
    from dtos.auth import LoginRequest, RegisterRequest

    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)

    with Session(engine) as session:
        usuario = auth_service.registrar(
            session,
            RegisterRequest(
                nome="Teste",
                username="usuario_teste",
                email="teste@example.com",
                senha="Senha123!",
            ),
        )
        session.commit()

        _, access_token, refresh_token = auth_service.login(
            session,
            LoginRequest(email="teste@example.com", senha="Senha123!"),
        )
        session.commit()

        assert auth_service.validar_token(access_token) == usuario.id
        assert refresh_token != access_token

        _, novo_access_token, novo_refresh_token = auth_service.refresh_access_token(
            session, refresh_token
        )
        session.commit()

        assert auth_service.validar_token(novo_access_token) == usuario.id
        assert novo_refresh_token != refresh_token

        try:
            auth_service.refresh_access_token(session, refresh_token)
        except ValueError:
            pass
        else:
            raise AssertionError("Refresh token rotacionado deveria ser rejeitado")

        token_novo = auth_service._hash_token(novo_refresh_token)
        registro_novo = auth_service.auth_repository.buscar_refresh_token_por_hash(
            session, token_novo
        )
        assert registro_novo.revoked_at is not None

        _, _, token_logout = auth_service.login(
            session,
            LoginRequest(email="teste@example.com", senha="Senha123!"),
        )
        session.commit()
        auth_service.logout(session, token_logout)
        session.commit()

        registro_logout = auth_service.auth_repository.buscar_refresh_token_por_hash(
            session, auth_service._hash_token(token_logout)
        )
        assert registro_logout.revoked_at is not None


def test_http_behind_proxy_is_redirected_to_https():
    from main import app

    client = TestClient(app)
    response = client.get(
        "/health",
        headers={"X-Forwarded-Proto": "http", "Host": "softspend.com.br"},
        follow_redirects=False,
    )

    assert response.status_code == 308
    assert response.headers["Location"].startswith("https://")
    assert "Strict-Transport-Security" in response.headers


def test_https_behind_proxy_includes_hsts_header():
    from main import app

    client = TestClient(app)
    response = client.get(
        "/health",
        headers={"X-Forwarded-Proto": "https", "Host": "softspend.com.br"},
        follow_redirects=False,
    )

    # A rota /health pode falhar por falta de banco no CI, mas a resposta deve
    # trafegar pelo middleware e incluir o cabecalho HSTS.
    assert response.status_code in (200, 503)
    assert "Strict-Transport-Security" in response.headers


def test_pluggy_webhook_requires_configured_secret(monkeypatch):
    from main import app

    monkeypatch.delenv("PLUGGY_WEBHOOK_SECRET", raising=False)
    client = TestClient(app)

    response = client.post(
        "/api/webhooks/pluggy",
        json={"event": "item/created", "eventId": "event-1", "itemId": "item-1"},
    )

    assert response.status_code == 503


def test_pluggy_webhook_processes_valid_event_in_background(monkeypatch):
    from main import app
    from services import open_finance_service

    eventos = []

    async def processar(evento):
        eventos.append(evento)

    monkeypatch.setenv("PLUGGY_WEBHOOK_SECRET", "webhook-secret")
    monkeypatch.setattr(open_finance_service, "processar_evento", processar)
    client = TestClient(app)

    response = client.post(
        "/api/webhooks/pluggy",
        headers={"X-Pluggy-Webhook-Secret": "webhook-secret"},
        json={
            "event": "item/created",
            "eventId": "event-1",
            "itemId": "item-1",
            "clientUserId": "user-1",
            "triggeredBy": "USER",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"received": True}
    assert eventos[0]["event"] == "item/created"
    assert eventos[0]["itemId"] == "item-1"


def test_pluggy_webhook_rejects_invalid_secret(monkeypatch):
    from main import app

    monkeypatch.setenv("PLUGGY_WEBHOOK_SECRET", "webhook-secret")
    client = TestClient(app)

    response = client.post(
        "/api/webhooks/pluggy",
        headers={"X-Pluggy-Webhook-Secret": "wrong"},
        json={"event": "item/created", "eventId": "event-1"},
    )

    assert response.status_code == 401


def test_pluggy_webhook_accepts_secret_in_url_token(monkeypatch):
    from main import app
    from services import open_finance_service

    eventos = []

    async def processar(evento):
        eventos.append(evento)

    monkeypatch.setenv("PLUGGY_WEBHOOK_SECRET", "webhook-secret")
    monkeypatch.setattr(open_finance_service, "processar_evento", processar)
    client = TestClient(app)

    response = client.post(
        "/api/webhooks/pluggy?token=webhook-secret",
        json={"event": "item/updated", "eventId": "event-2", "itemId": "item-1"},
    )

    assert response.status_code == 200
    assert eventos[0]["event"] == "item/updated"


def test_pluggy_webhook_accepts_dashboard_probe_with_empty_body(monkeypatch):
    from main import app

    monkeypatch.setenv("PLUGGY_WEBHOOK_SECRET", "webhook-secret")
    client = TestClient(app)

    response = client.post(
        "/api/webhooks/pluggy?token=webhook-secret",
        headers={"Content-Type": "application/json"},
    )

    assert response.status_code == 200
    assert response.json() == {"received": True, "ignored": "empty_body"}


def test_connect_token_uses_authenticated_user(monkeypatch):
    from dependencies import get_current_user_id
    from main import app
    from services import open_finance_service

    chamadas = []

    async def criar_connect_token(**kwargs):
        chamadas.append(kwargs)
        return "connect-token"

    monkeypatch.setattr(open_finance_service, "criar_connect_token", criar_connect_token)
    app.dependency_overrides[get_current_user_id] = lambda: "user-1"
    try:
        client = TestClient(app)
        response = client.post(
            "/api/connect-token",
            json={
                "itemId": "item-1",
                "oauthRedirectUri": "softspend://oauth",
                "avoidDuplicates": False,
            },
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json() == {"accessToken": "connect-token"}
    assert chamadas == [
        {
            "client_user_id": "user-1",
            "item_id": "item-1",
            "oauth_redirect_uri": "softspend://oauth",
            "avoid_duplicates": False,
        }
    ]

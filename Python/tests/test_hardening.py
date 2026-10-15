import asyncio
import ipaddress
from datetime import datetime, timezone
from decimal import Decimal
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


def test_pluggy_transactions_follow_v2_cursor():
    from services import open_finance_service

    chamadas = []

    class Response:
        status_code = 200

        def __init__(self, payload):
            self.payload = payload

        def json(self):
            return self.payload

    class Client:
        async def get(self, path, params=None, headers=None):
            chamadas.append({"path": path, "params": params, "headers": headers})
            if len(chamadas) == 1:
                return Response(
                    {
                        "results": [{"id": "tx-1"}],
                        "next": "?accountId=acc-1&after=cursor-1",
                    }
                )
            return Response({"results": [{"id": "tx-2"}]})

    transacoes = asyncio.run(
        open_finance_service._listar_transacoes(Client(), "api-key", "acc-1")
    )

    assert [t["id"] for t in transacoes] == ["tx-1", "tx-2"]
    assert chamadas[0]["path"] == "/v2/transactions"
    assert chamadas[0]["params"] == {"accountId": "acc-1"}
    assert chamadas[0]["headers"]["X-API-KEY"] == "api-key"
    assert chamadas[1]["path"] == "/v2/transactions?accountId=acc-1&after=cursor-1"
    assert chamadas[1]["params"] is None


def test_pluggy_item_import_filters_credit_card_accounts(monkeypatch):
    from services import open_finance_service

    chamadas = []
    persistido = []

    class Response:
        def __init__(self, payload, status_code=200):
            self.payload = payload
            self.status_code = status_code
            self.request = None

        def json(self):
            return self.payload

    class FakeAsyncClient:
        def __init__(self, base_url, timeout):
            self.base_url = base_url

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, path, json=None, headers=None):
            chamadas.append({"method": "POST", "path": path, "json": json})
            return Response({"apiKey": "api-key"})

        async def get(self, path, params=None, headers=None):
            chamadas.append({"method": "GET", "path": path, "params": params})
            if path == "/items/item-1":
                return Response(
                    {
                        "id": "item-1",
                        "clientUserId": "user-1",
                        "status": "UPDATED",
                        "connector": {"name": "Banco Teste"},
                    }
                )
            if path == "/accounts":
                return Response(
                    {
                        "results": [
                            {
                                "id": "acc-card",
                                "type": "CREDIT",
                                "subtype": "CREDIT_CARD",
                            },
                            {
                                "id": "acc-bank",
                                "type": "BANK",
                                "subtype": "CHECKING_ACCOUNT",
                            },
                        ],
                        "totalPages": 1,
                    }
                )
            if path == "/bills":
                return Response({"results": [{"id": "bill-1"}], "totalPages": 1})
            if path == "/v2/transactions":
                return Response({"results": [{"id": "tx-1"}]})
            raise AssertionError(f"Path inesperado: {path}")

    monkeypatch.setenv("PLUGGY_CLIENT_ID", "client-id")
    monkeypatch.setenv("PLUGGY_CLIENT_SECRET", "client-secret")
    monkeypatch.setattr(
        open_finance_service, "_api_key_cache", {"key": None, "expires_at": None}
    )
    monkeypatch.setattr(open_finance_service.httpx, "AsyncClient", FakeAsyncClient)
    monkeypatch.setattr(
        open_finance_service,
        "_persistir_importacao",
        lambda dados: persistido.append(dados) or dados,
    )

    asyncio.run(open_finance_service.sincronizar_item("item-1", "user-1"))

    paths = [chamada["path"] for chamada in chamadas]
    assert paths == [
        "/auth",
        "/items/item-1",
        "/accounts",
        "/bills",
        "/v2/transactions",
    ]
    assert chamadas[2]["params"]["itemId"] == "item-1"
    assert chamadas[2]["params"]["type"] == "CREDIT"
    assert len(persistido[0]["accounts"]) == 1
    assert persistido[0]["accounts"][0]["account"]["id"] == "acc-card"


def test_pluggy_unsupported_bills_do_not_fail_card_import():
    import httpx
    from services import open_finance_service

    class Client:
        async def get(self, path, params=None, headers=None):
            request = httpx.Request("GET", "https://api.pluggy.ai/bills")
            return httpx.Response(
                404,
                json={"message": "Produto não suportado"},
                request=request,
            )

    assert asyncio.run(
        open_finance_service._listar_faturas(Client(), "api-key", "acc-1")
    ) == []


def test_open_finance_import_persists_invoice_idempotently(monkeypatch):
    from database import Base
    import models
    from services import open_finance_service

    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add(
        models.User(
            id="user-1",
            nome="Teste",
            username="teste",
            email="teste@example.com",
            senha_hash="hash",
        )
    )
    session.commit()
    monkeypatch.setattr(open_finance_service, "SessionLocal", lambda: session)

    dados = {
        "item_id": "item-1",
        "item": {
            "id": "item-1",
            "clientUserId": "user-1",
            "status": "UPDATED",
            "connector": {"name": "Banco Teste"},
        },
        "accounts": [
            {
                "account": {
                    "id": "acc-1",
                    "type": "CREDIT",
                    "subtype": "CREDIT_CARD",
                    "name": "Cartão corporativo",
                    "number": "xxxx1234",
                    "currencyCode": "BRL",
                    "balance": "1000.50",
                    "creditData": {
                        "brand": "VISA",
                        "level": "BUSINESS",
                        "status": "ACTIVE",
                        "creditLimit": "5000",
                        "availableCreditLimit": "3999.50",
                        "minimumPayment": "150",
                        "balanceCloseDate": "2026-10-10T00:00:00.000Z",
                        "balanceDueDate": "2026-10-20T00:00:00.000Z",
                    },
                },
                "bills": [
                    {
                        "id": "bill-1",
                        "dueDate": "2026-10-20T00:00:00.000Z",
                        "billClosingDate": "2026-10-10T00:00:00.000Z",
                        "totalAmount": "1000.50",
                        "totalAmountCurrencyCode": "BRL",
                        "minimumPaymentAmount": "150",
                        "allowsInstallments": True,
                    }
                ],
                "transactions": [
                    {
                        "id": "tx-1",
                        "description": "RESTAURANTE TESTE",
                        "amount": "82.40",
                        "currencyCode": "BRL",
                        "date": "2026-10-14T12:00:00.000Z",
                        "status": "POSTED",
                        "type": "DEBIT",
                        "merchant": {"name": "Restaurante Teste"},
                        "creditCardMetadata": {
                            "billId": "bill-1",
                            "cardNumber": "1234",
                        },
                    }
                ],
            }
        ],
    }

    primeiro = open_finance_service._persistir_importacao(dados)
    segundo = open_finance_service._persistir_importacao(dados)

    assert primeiro == segundo == {
        "item_id": "item-1",
        "cartoes": 1,
        "faturas": 1,
        "transacoes": 1,
        "conciliacoes": 0,
    }
    assert session.query(models.OpenFinanceConnection).count() == 1
    assert session.query(models.CreditCardAccount).count() == 1
    assert session.query(models.CreditCardBill).count() == 1
    assert session.query(models.CreditCardTransaction).count() == 1

    transacao = session.query(models.CreditCardTransaction).one()
    fatura = session.query(models.CreditCardBill).one()
    cartao = session.query(models.CreditCardAccount).one()
    assert transacao.fatura_id == fatura.id
    assert str(transacao.amount) == "82.40"
    assert cartao.number_last4 == "1234"
    assert cartao.institution_name == "Banco Teste"


def test_open_finance_reconciliation_links_gasto_to_invoice_transaction():
    from database import Base
    from dtos.gasto.gasto_response import GastoResponse
    from services import open_finance_reconciliation_service
    import models

    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        usuario = models.User(
            id="user-1",
            nome="Teste",
            username="teste",
            email="teste@example.com",
            senha_hash="hash",
        )
        ciclo = models.Ciclo(id_usuario="user-1", titulo="Ciclo")
        dia = models.Dia(
            ciclo=ciclo,
            data=datetime(2026, 10, 14, tzinfo=timezone.utc),
            saldo=Decimal("100.00"),
        )
        gasto = models.Gasto(
            dia=dia,
            titulo="Restaurante Teste",
            valor=Decimal("82.40"),
            categoria="ALIMENTACAO",
        )
        conexao = models.OpenFinanceConnection(
            user_id="user-1", provider="pluggy", item_id="item-1"
        )
        session.add_all([usuario, ciclo, conexao])
        session.flush()
        cartao = models.CreditCardAccount(
            conexao_id=conexao.id,
            user_id="user-1",
            account_id="acc-1",
        )
        fatura = models.CreditCardBill(
            cartao=cartao,
            user_id="user-1",
            bill_id="bill-1",
            total_amount=Decimal("82.40"),
        )
        transacao = models.CreditCardTransaction(
            cartao=cartao,
            fatura=fatura,
            user_id="user-1",
            transaction_id="tx-1",
            description="RESTAURANTE TESTE",
            amount=Decimal("82.40"),
            date=datetime(2026, 10, 14, tzinfo=timezone.utc),
            status="POSTED",
            type="DEBIT",
        )
        session.add_all([gasto, cartao, fatura, transacao])
        session.commit()

        total = open_finance_reconciliation_service.conciliar_usuario(
            session, "user-1"
        )
        session.commit()

        assert total == 1
        assert gasto.open_finance_status == "AUTO_MATCHED"
        assert gasto.open_finance_match.cartao_transacao_id == transacao.id
        resposta = GastoResponse.model_validate(gasto)
        assert resposta.open_finance_status == "AUTO_MATCHED"
        assert resposta.open_finance_match.provider_transaction_id == "tx-1"
        assert resposta.open_finance_match.transaction_description == "RESTAURANTE TESTE"


def test_open_finance_reconciliation_marks_ambiguous_match_for_review():
    from database import Base
    from services import open_finance_reconciliation_service
    import models

    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        usuario = models.User(
            id="user-1",
            nome="Teste",
            username="teste",
            email="teste@example.com",
            senha_hash="hash",
        )
        ciclo = models.Ciclo(id_usuario="user-1", titulo="Ciclo")
        dia = models.Dia(
            ciclo=ciclo,
            data=datetime(2026, 10, 14, tzinfo=timezone.utc),
            saldo=Decimal("100.00"),
        )
        gasto = models.Gasto(
            dia=dia,
            titulo="Almoço",
            valor=Decimal("50.00"),
            categoria="ALIMENTACAO",
        )
        conexao = models.OpenFinanceConnection(
            user_id="user-1", provider="pluggy", item_id="item-1"
        )
        session.add_all([usuario, ciclo, conexao])
        session.flush()
        cartao = models.CreditCardAccount(
            conexao_id=conexao.id,
            user_id="user-1",
            account_id="acc-1",
        )
        session.add(cartao)
        session.flush()
        transacoes = [
            models.CreditCardTransaction(
                cartao_id=cartao.id,
                user_id="user-1",
                transaction_id="tx-1",
                description="RESTAURANTE A",
                amount=Decimal("50.00"),
                date=datetime(2026, 10, 14, tzinfo=timezone.utc),
                status="POSTED",
                type="DEBIT",
            ),
            models.CreditCardTransaction(
                cartao_id=cartao.id,
                user_id="user-1",
                transaction_id="tx-2",
                description="RESTAURANTE B",
                amount=Decimal("50.00"),
                date=datetime(2026, 10, 14, tzinfo=timezone.utc),
                status="POSTED",
                type="DEBIT",
            ),
        ]
        session.add_all([gasto] + transacoes)
        session.commit()

        total = open_finance_reconciliation_service.conciliar_usuario(
            session, "user-1"
        )

        assert total == 1
        assert gasto.open_finance_status == "REVIEW"
        assert gasto.open_finance_match.score >= 65


def test_pluggy_item_webhook_triggers_import(monkeypatch):
    from services import open_finance_service

    chamadas = []

    async def sincronizar(item_id, event_client_user_id=None):
        chamadas.append((item_id, event_client_user_id))

    monkeypatch.setattr(open_finance_service, "sincronizar_item", sincronizar)
    asyncio.run(
        open_finance_service.processar_evento(
            {
                "event": "item/updated",
                "eventId": "event-1",
                "itemId": "item-1",
                "clientUserId": "user-1",
            }
        )
    )

    assert chamadas == [("item-1", "user-1")]


def test_open_finance_cards_are_scoped_to_authenticated_user(monkeypatch, tmp_path):
    from database import Base, get_db
    from dependencies import get_current_user_id
    from main import app
    import models

    engine = create_engine(f"sqlite:///{tmp_path}/open_finance.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(
                id="user-1",
                nome="Um",
                username="um",
                email="um@example.com",
                senha_hash="hash",
            ),
            models.User(
                id="user-2",
                nome="Dois",
                username="dois",
                email="dois@example.com",
                senha_hash="hash",
            ),
        ]
    )
    session.flush()
    for user_id, item_id, account_id in (
        ("user-1", "item-1", "acc-1"),
        ("user-2", "item-2", "acc-2"),
    ):
        conexao = models.OpenFinanceConnection(
            user_id=user_id, provider="pluggy", item_id=item_id
        )
        session.add(conexao)
        session.flush()
        session.add(
            models.CreditCardAccount(
                conexao_id=conexao.id,
                user_id=user_id,
                account_id=account_id,
                name=f"Cartão {user_id}",
            )
        )
    cartao_usuario = session.query(models.CreditCardAccount).filter_by(
        user_id="user-1"
    ).one()
    fatura_usuario = models.CreditCardBill(
        cartao_id=cartao_usuario.id,
        user_id="user-1",
        bill_id="bill-1",
        total_amount=Decimal("82.40"),
    )
    transacao_usuario = models.CreditCardTransaction(
        cartao_id=cartao_usuario.id,
        fatura=fatura_usuario,
        user_id="user-1",
        transaction_id="tx-1",
        description="RESTAURANTE TESTE",
        amount=Decimal("82.40"),
    )
    cartao_outro = session.query(models.CreditCardAccount).filter_by(
        user_id="user-2"
    ).one()
    fatura_outra = models.CreditCardBill(
        cartao_id=cartao_outro.id,
        user_id="user-2",
        bill_id="bill-2",
        total_amount=Decimal("100.00"),
    )
    ciclo = models.Ciclo(id_usuario="user-1", titulo="Ciclo")
    dia = models.Dia(
        ciclo=ciclo,
        data=datetime(2026, 10, 14, tzinfo=timezone.utc),
        saldo=Decimal("100.00"),
    )
    gasto = models.Gasto(
        dia=dia,
        titulo="Restaurante",
        valor=Decimal("82.40"),
        categoria="ALIMENTACAO",
    )
    session.add_all([fatura_usuario, transacao_usuario, fatura_outra, gasto])
    session.flush()
    match_usuario = models.ExpenseTransactionMatch(
        gasto=gasto,
        transacao=transacao_usuario,
        status="REVIEW",
        score=70,
        method="RULES",
    )
    session.add(match_usuario)
    session.commit()

    def override_db():
        yield session

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_current_user_id] = lambda: "user-1"
    try:
        client = TestClient(app)
        response = client.get("/api/open-finance/cards")
        response_fatura = client.get(
            f"/api/open-finance/bills/{fatura_usuario.id}"
        )
        response_fatura_outra = client.get(
            f"/api/open-finance/bills/{fatura_outra.id}"
        )
        response_matches = client.get("/api/open-finance/matches")
        response_confirm = client.post(
            f"/api/open-finance/matches/{match_usuario.id}/confirm"
        )
        response_delete = client.delete(
            f"/api/open-finance/matches/{match_usuario.id}"
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert len(response.json()) == 1
    assert response.json()[0]["account_id"] == "acc-1"
    assert response_fatura.status_code == 200
    assert response_fatura.json()["transacoes"][0]["transaction_id"] == "tx-1"
    assert response_fatura.json()["transacoes"][0]["open_finance_match"]["status"] == "REVIEW"
    assert response_fatura_outra.status_code == 404
    assert len(response_matches.json()) == 1
    assert response_confirm.status_code == 200
    assert response_confirm.json()["status"] == "CONFIRMED"
    assert response_confirm.json()["confirmed_by_user"] is True
    assert response_delete.status_code == 200


def test_open_finance_manual_sync_uses_authenticated_user(monkeypatch):
    from dependencies import get_current_user_id
    from main import app
    from services import open_finance_service

    chamadas = []

    async def sincronizar(item_id, expected_user_id=None):
        chamadas.append((item_id, expected_user_id))
        return {
            "item_id": item_id,
            "cartoes": 1,
            "faturas": 2,
            "transacoes": 3,
            "conciliacoes": 1,
        }

    monkeypatch.setattr(open_finance_service, "sincronizar_item", sincronizar)
    app.dependency_overrides[get_current_user_id] = lambda: "user-1"
    try:
        response = TestClient(app).post("/api/open-finance/items/item-1/sync")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json() == {
        "item_id": "item-1",
        "cartoes": 1,
        "faturas": 2,
        "transacoes": 3,
        "conciliacoes": 1,
    }
    assert chamadas == [("item-1", "user-1")]

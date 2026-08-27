import ipaddress
from unittest.mock import patch

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

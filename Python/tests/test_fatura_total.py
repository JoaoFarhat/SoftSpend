"""Teto do `total_amount` da fatura importada (coluna Numeric(14, 2)).

Um PDF mal lido pela IA ou um OFX/CSV com total errado (ex.: 10^13) faria o
MySQL recusar o INSERT e o `POST /api/faturas` caía com 500 — a pessoa não
conseguia importar nem as compras certas. Total acima de
`TOTAL_MAXIMO_FATURA` vira NULL (o campo é só informativo); dentro do
limite, inclusive negativo, é gravado como veio. Montagem no molde de
`test_fatura_s2.py`.
"""

import importlib
import sys
from datetime import date
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

USER_A = "user-1"
INICIO = date(2026, 10, 1)


# ---------------------------------------------------------------- helpers


def _ofx(
    transacoes,
    emissor="Banco Teste",
    dtend="20261007",
    dtasof="20261020",
    balamt="500.00",
) -> bytes:
    """Monta um OFX mínimo. `transacoes`: (TRNTYPE, DTPOSTED, TRNAMT, MEMO)."""
    linhas = [
        "OFXHEADER:100",
        "DATA:OFXSGML",
        "VERSION:102",
        "<OFX>",
        "<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS>"
        f"<DTSERVER>20261020<LANGUAGE>POR<FI><ORG>{emissor}</FI></SONRS>"
        "</SIGNONMSGSRSV1>",
        "<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL"
        "<CCACCTFROM><ACCTID>1234</CCACCTFROM>",
        f"<BANKTRANLIST><DTSTART>20260901000000<DTEND>{dtend}000000",
    ]
    for i, (trntype, dtposted, trnamt, memo) in enumerate(transacoes):
        linhas.append(
            f"<STMTTRN><TRNTYPE>{trntype}<DTPOSTED>{dtposted}000000"
            f"<TRNAMT>{trnamt}<FITID>t{i}<MEMO>{memo}</STMTTRN>"
        )
    linhas += [
        "</BANKTRANLIST>",
        f"<LEDGERBAL><BALAMT>{balamt}<DTASOF>{dtasof}000000</LEDGERBAL>",
        "</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>",
    ]
    return "\n".join(linhas).encode()


def _data(d: date) -> str:
    return d.strftime("%Y%m%d")


class _Ambiente:
    def __init__(self, app, session):
        self.app = app
        self.session = session

    def como(self, user_id: str) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app)


@pytest.fixture
def ambiente(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module
    import models

    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/fatura_total.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add(
        models.User(
            id=USER_A, nome="A", username="a", email="a@e.com",
            senha_hash="hash",
        )
    )
    session.commit()

    def override_db():
        yield session

    app.dependency_overrides[get_db] = override_db
    try:
        yield _Ambiente(app, session)
    finally:
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


def _ler(client, conteudo: bytes, **form) -> dict:
    resposta = client.post(
        "/api/faturas/ler",
        files={"arquivo": ("fatura.ofx", conteudo, "application/ofx")},
        data={k: str(v) for k, v in form.items() if v is not None},
    )
    assert resposta.status_code == 200, resposta.text
    return resposta.json()


def _gravar(client, lida: dict) -> dict:
    resposta = client.post("/api/faturas", json=lida)
    assert resposta.status_code == 200, resposta.text
    return resposta.json()


# ------------------------------------------------------------------ testes


def test_total_acima_do_teto_grava_compras_e_total_fica_vazio(ambiente):
    """total_fatura de 10^13 estoura Numeric(14, 2): antes era 500 e nada
    era gravado. Agora a fatura sobe com total vazio e as compras vão."""
    import models

    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]),
    )
    lida["total_fatura"] = 10**13

    resposta = client.post("/api/faturas", json=lida)
    assert resposta.status_code == 200, resposta.text
    detalhe = resposta.json()
    assert detalhe["total_amount"] is None
    assert len(detalhe["transacoes"]) == 1
    assert detalhe["transacoes"][0]["description"] == "CAFE"

    session = ambiente.session
    fatura = session.query(models.CreditCardBill).one()
    assert fatura.total_amount is None
    assert session.query(models.CreditCardTransaction).count() == 1


def test_total_normal_grava_como_veio(ambiente):
    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx(
            [("DEBIT", _data(INICIO), "-100.00", "SUPERMERCADO")],
            balamt="132.40",
        ),
    )

    detalhe = _gravar(client, lida)
    assert detalhe["total_amount"] == 132.40


def test_total_negativo_pequeno_grava_como_veio(ambiente):
    """Total negativo dentro do limite continua valendo."""
    import models

    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]),
    )
    lida["total_fatura"] = -50.25

    detalhe = _gravar(client, lida)
    assert detalhe["total_amount"] == -50.25
    fatura = ambiente.session.query(models.CreditCardBill).one()
    assert fatura.total_amount == Decimal("-50.25")


def test_total_no_teto_exato_grava_como_veio(ambiente):
    """Só o que passa do teto vira NULL; o próprio teto é gravado."""
    from services.fatura_service import TOTAL_MAXIMO_FATURA

    client = ambiente.como(USER_A)
    lida = _ler(
        client,
        _ofx([("DEBIT", _data(INICIO), "-10.00", "CAFE")]),
    )
    lida["total_fatura"] = str(TOTAL_MAXIMO_FATURA)

    detalhe = _gravar(client, lida)
    assert detalhe["total_amount"] == float(TOTAL_MAXIMO_FATURA)

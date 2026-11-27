"""O `ler_fatura` roda o parse de OFX/CSV e a montagem da resposta fora do
laço de eventos.

`ler_ofx`, `ler_csv` e `montar_fatura_lida` são síncronas (regex e `csv`
sobre até 2 MB de texto). Rodadas dentro do `async def`, travavam o
processo inteiro do uvicorn enquanto uma fatura grande era lida — nem
`/health` respondia. Elas agora vão por `run_in_threadpool`, como já
acontecia com `desproteger_pdf` e `ler_fatura_pdf`.

O `run_in_threadpool` importado pelo controller é substituído por um
espião que registra cada função recebida e a executa na hora, então a
resposta tem que ser exatamente a mesma de antes.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient

from services import fatura_arquivo_service


# ---------------------------------------------------------------- helpers
# (mesmos exemplos de OFX e CSV do test_fatura.py)


_OFX = """OFXHEADER:100
DATA:OFXSGML
VERSION:102
<OFX>
<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS><DTSERVER>20261020<LANGUAGE>POR<FI><ORG>Banco Teste</FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL<CCACCTFROM><ACCTID>1234</CCACCTFROM>
<BANKTRANLIST><DTSTART>20260911000000<DTEND>20261010000000
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261001000000<TRNAMT>-100.00<FITID>t1<MEMO>SUPERMERCADO X</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261002000000<TRNAMT>-32.40<FITID>t2<MEMO>UBER TRIP</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261005000000<TRNAMT>10.00<FITID>t3<MEMO>ESTORNO LOJA</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261010000000<TRNAMT>122.40<FITID>t4<MEMO>PAGAMENTO RECEBIDO</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-122.40<DTASOF>20261020000000</LEDGERBAL>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
"""

_CSV = "Data;Descrição;Valor\n01/10/2026;Supermercado;100,00\n02/10/2026;Uber;32,40\n"


def _post(client: TestClient, conteudo: bytes, nome: str, content_type: str):
    return client.post(
        "/api/faturas/ler",
        files={"arquivo": (nome, conteudo, content_type)},
    )


@pytest.fixture
def app_fatura(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app

    import limiter as limiter_module

    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    from dependencies import get_current_user_id

    app.dependency_overrides[get_current_user_id] = lambda: "user-1"
    try:
        yield app
    finally:
        app.dependency_overrides.clear()


@pytest.fixture
def client(app_fatura):
    return TestClient(app_fatura)


@pytest.fixture
def espioes(app_fatura, monkeypatch):
    """Espia o `run_in_threadpool` do controller: registra a função
    recebida e a executa em seguida.

    O import é aqui dentro porque `controllers.fatura_controller` puxa
    `auth_service`, que exige a `SECRET_KEY` já na importação — e ela só
    existe depois da fixture `app_fatura`.
    """
    from controllers import fatura_controller

    chamadas = []

    async def espiao(func, *args, **kwargs):
        chamadas.append(func)
        return func(*args, **kwargs)

    monkeypatch.setattr(fatura_controller, "run_in_threadpool", espiao)
    return chamadas


# ------------------------------------------------------------------- CSV


def test_ler_csv_passa_pelo_threadpool(client, espioes):
    resposta = _post(client, _CSV.encode("utf-8"), "fatura.csv", "text/csv")

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert [(c["descricao"], c["valor"], c["tipo"]) for c in corpo["compras"]] == [
        ("Supermercado", 100.0, "COMPRA"),
        ("Uber", 32.40, "COMPRA"),
    ]
    assert corpo["soma_confere"] is None
    assert corpo["total_fatura"] is None
    assert fatura_arquivo_service.ler_csv in espioes
    assert fatura_arquivo_service.montar_fatura_lida in espioes
    assert fatura_arquivo_service.ler_ofx not in espioes


# ------------------------------------------------------------------- OFX


def test_ler_ofx_passa_pelo_threadpool(client, espioes):
    resposta = _post(client, _OFX.encode(), "fatura.ofx", "application/ofx")

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["emissor"] == "Banco Teste"
    assert corpo["total_fatura"] == 122.40
    assert corpo["soma_confere"] is True
    assert [(c["descricao"], c["valor"], c["tipo"]) for c in corpo["compras"]] == [
        ("SUPERMERCADO X", 100.0, "COMPRA"),
        ("UBER TRIP", 32.40, "COMPRA"),
        ("ESTORNO LOJA", 10.0, "ESTORNO"),
    ]
    assert fatura_arquivo_service.ler_ofx in espioes
    assert fatura_arquivo_service.montar_fatura_lida in espioes
    assert fatura_arquivo_service.ler_csv not in espioes

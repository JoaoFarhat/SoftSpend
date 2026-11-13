"""Testes do POST /api/faturas/ler (tarefa S1 da spec cartao-sem-open-finance).

O Gemini é substituído por um falso (`_client` do `fatura_ia_service`):
nenhum teste faz chamada real. O rate limit é desligado porque ele é por IP
e tornaria a suite dependente do total de requisições.
"""

import importlib
import io
import logging
import sys
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from reportlab.lib.pdfencrypt import StandardEncryption
from reportlab.pdfgen import canvas
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

from enums.categoria_enum import Categoria
from services import fatura_ia_service
from services.fatura_ia_service import CompraExtraida, FaturaExtraida


# ---------------------------------------------------------------- helpers


def _pdf(paginas: int = 1, texto: str = "FATURA") -> bytes:
    buffer = io.BytesIO()
    c = canvas.Canvas(buffer)
    for _ in range(paginas):
        c.drawString(72, 720, texto)
        c.showPage()
    c.save()
    return buffer.getvalue()


def _pdf_com_senha(senha: str = "1234") -> bytes:
    buffer = io.BytesIO()
    cripto = StandardEncryption(userPassword=senha, ownerPassword=senha)
    c = canvas.Canvas(buffer, encrypt=cripto)
    c.drawString(72, 720, "FATURA SECRETA")
    c.showPage()
    c.save()
    return buffer.getvalue()


def _png() -> bytes:
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (8, 8), (200, 0, 0)).save(buffer, format="PNG")
    return buffer.getvalue()


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


class _ClienteGeminiFalso:
    """Imita `_client.models.generate_content` do google-genai."""

    def __init__(self, resposta):
        self.resposta = resposta
        self.chamadas = []
        self.models = self

    def generate_content(self, **kwargs):
        self.chamadas.append(kwargs)
        return self.resposta


def _resposta_gemini(fatura: FaturaExtraida, finish_reason: str = "STOP"):
    return SimpleNamespace(
        parsed=fatura,
        text="",
        candidates=[SimpleNamespace(finish_reason=finish_reason)],
        usage_metadata=SimpleNamespace(
            prompt_token_count=123, candidates_token_count=45
        ),
    )


def _fatura_extraida(**kwargs) -> FaturaExtraida:
    dados = {
        "emissor": "Banco Teste",
        "final_cartao": "1234 5678",
        "fechamento": "2026-10-10",
        "vencimento": "2026-10-20",
        "total_fatura": 132.40,
        "compras": [
            CompraExtraida(
                data="2026-10-01",
                descricao="SUPERMERCADO",
                valor=100.0,
                categoria=Categoria.ALIMENTACAO,
            ),
            CompraExtraida(
                data="2026-10-02",
                descricao="UBER TRIP",
                valor=32.40,
                categoria=Categoria.TRANSPORTE,
            ),
        ],
    }
    dados.update(kwargs)
    return FaturaExtraida(**dados)


def _post(client: TestClient, conteudo: bytes, nome: str, content_type: str, **form):
    return client.post(
        "/api/faturas/ler",
        files={"arquivo": (nome, conteudo, content_type)},
        data={k: v for k, v in form.items() if v is not None},
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
def gemini(monkeypatch):
    """Instala um Gemini falso e devolve a função que define a próxima resposta."""
    falso = _ClienteGeminiFalso(_resposta_gemini(_fatura_extraida()))
    monkeypatch.setattr(fatura_ia_service, "_client", falso)
    return falso


# ------------------------------------------------------------------- PDF


def test_pdf_valido_devolve_compras(client, gemini):
    resposta = _post(client, _pdf(), "fatura.pdf", "application/pdf")

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["emissor"] == "Banco Teste"
    assert corpo["final_cartao"] == "5678"
    assert corpo["fechamento"] == "2026-10-10"
    assert corpo["vencimento"] == "2026-10-20"
    assert corpo["total_fatura"] == 132.40
    assert corpo["moeda"] == "BRL"
    assert corpo["soma_confere"] is True
    assert corpo["diferenca"] == 0
    assert len(corpo["compras"]) == 2
    compra = corpo["compras"][0]
    assert compra["indice"] == 0
    assert compra["descricao"] == "SUPERMERCADO"
    assert compra["valor"] == 100.0
    assert compra["tipo"] == "COMPRA"
    assert compra["categoria"] == "ALIMENTACAO"
    assert compra["dentro_da_viagem"] is False
    assert compra["dia_id"] is None
    assert compra["match"] is None


def test_pdf_11mb_da_413(client, gemini):
    conteudo = b"%PDF-1.7\n" + b"9" * (11 * 1024 * 1024)
    resposta = _post(client, conteudo, "fatura.pdf", "application/pdf")
    assert resposta.status_code == 413


def test_pdf_mais_de_20_paginas_rejeitado(client, gemini):
    resposta = _post(client, _pdf(paginas=21), "fatura.pdf", "application/pdf")
    assert resposta.status_code == 413


def test_arquivo_de_outro_tipo_da_400(client, gemini):
    resposta = _post(client, _png(), "foto.png", "image/png")
    assert resposta.status_code == 400


def test_imagem_renomeada_como_pdf_da_400(client, gemini):
    resposta = _post(client, _png(), "fatura.pdf", "application/pdf")
    assert resposta.status_code == 400


def test_pdf_com_senha_certa(client, gemini):
    resposta = _post(
        client, _pdf_com_senha("1234"), "fatura.pdf", "application/pdf", senha="1234"
    )
    assert resposta.status_code == 200
    assert len(resposta.json()["compras"]) == 2


def test_pdf_com_senha_errada_da_422(client, gemini):
    resposta = _post(
        client, _pdf_com_senha("1234"), "fatura.pdf", "application/pdf", senha="9999"
    )
    assert resposta.status_code == 422


def test_pdf_com_senha_ausente_da_422(client, gemini):
    resposta = _post(client, _pdf_com_senha(), "fatura.pdf", "application/pdf")
    assert resposta.status_code == 422


# ------------------------------------------------------------------- OFX


def test_ofx_com_sinais_invertidos(client):
    # TRNAMT negativo em DEBIT é comum: a compra vale positivo na prévia.
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


def test_ofx_sem_trntype_usa_sinal_da_maioria(client):
    # Sem TRNTYPE: a maioria negativa vira compra.
    ofx = _OFX.replace("<TRNTYPE>DEBIT", "<X>").replace("<TRNTYPE>CREDIT", "<X>")
    resposta = _post(client, ofx.encode(), "fatura.ofx", "application/ofx")

    assert resposta.status_code == 200
    compras = resposta.json()["compras"]
    assert [(c["descricao"], c["tipo"]) for c in compras] == [
        ("SUPERMERCADO X", "COMPRA"),
        ("UBER TRIP", "COMPRA"),
        ("ESTORNO LOJA", "ESTORNO"),
    ]


def test_ofx_pagamento_sai_da_lista(client):
    resposta = _post(client, _OFX.encode(), "fatura.ofx", "application/ofx")
    assert resposta.status_code == 200
    descricoes = [c["descricao"] for c in resposta.json()["compras"]]
    assert "PAGAMENTO RECEBIDO" not in descricoes


# ------------------------------------------------------------------- CSV


def test_csv_conhecido(client):
    resposta = _post(client, _CSV.encode("utf-8"), "fatura.csv", "text/csv")

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert [(c["descricao"], c["valor"]) for c in corpo["compras"]] == [
        ("Supermercado", 100.0),
        ("Uber", 32.40),
    ]
    assert corpo["soma_confere"] is None
    assert corpo["total_fatura"] is None


def test_csv_desconhecido_da_422(client):
    resposta = _post(
        client, b"foo,bar,baz\n1,2,3\n", "dados.csv", "text/csv"
    )
    assert resposta.status_code == 422


# ------------------------------------------- validação e soma da fatura


def test_resposta_cortada_por_max_tokens_da_422(client, monkeypatch):
    falso = _ClienteGeminiFalso(
        _resposta_gemini(_fatura_extraida(), finish_reason="MAX_TOKENS")
    )
    monkeypatch.setattr(fatura_ia_service, "_client", falso)

    resposta = _post(client, _pdf(), "fatura.pdf", "application/pdf")
    assert resposta.status_code == 422
    assert "OFX ou CSV" in resposta.json()["error"]


def test_compras_invalidas_descartadas_com_aviso(client, monkeypatch):
    falso = _ClienteGeminiFalso(
        _resposta_gemini(
            _fatura_extraida(
                total_fatura=100.0,
                compras=[
                    CompraExtraida(data="2026-10-01", descricao="OK", valor=100.0),
                    CompraExtraida(data="2026-10-01", descricao="ZERO", valor=0),
                    CompraExtraida(data="1990-01-01", descricao="ANTIGA", valor=50.0),
                    CompraExtraida(data="2026-10-03", descricao="  ", valor=20.0),
                    CompraExtraida(data="2026-10-04", descricao="CARA", valor=150000.0),
                ],
            )
        )
    )
    monkeypatch.setattr(fatura_ia_service, "_client", falso)

    resposta = _post(client, _pdf(), "fatura.pdf", "application/pdf")
    assert resposta.status_code == 200
    corpo = resposta.json()
    assert [c["descricao"] for c in corpo["compras"]] == ["OK"]
    assert len(corpo["avisos"]) == 4


def test_soma_confere_falso(client, monkeypatch):
    falso = _ClienteGeminiFalso(
        _resposta_gemini(_fatura_extraida(total_fatura=200.0))
    )
    monkeypatch.setattr(fatura_ia_service, "_client", falso)

    resposta = _post(client, _pdf(), "fatura.pdf", "application/pdf")
    corpo = resposta.json()
    assert corpo["soma_confere"] is False
    assert corpo["diferenca"] == -67.60
    assert any("soma" in a for a in corpo["avisos"])


def test_soma_confere_verdadeiro(client, gemini):
    resposta = _post(client, _pdf(), "fatura.pdf", "application/pdf")
    assert resposta.json()["soma_confere"] is True


# -------------------------------------------------- configuração e rotas


def test_sem_gemini_key_pdf_da_503_mas_ofx_e_csv_funcionam(client, monkeypatch):
    monkeypatch.setattr(fatura_ia_service, "_client", None)

    assert _post(client, _pdf(), "fatura.pdf", "application/pdf").status_code == 503
    assert _post(client, _OFX.encode(), "fatura.ofx", "application/ofx").status_code == 200
    assert (
        _post(client, _CSV.encode(), "fatura.csv", "text/csv").status_code == 200
    )


def test_rota_sempre_registrada_sem_open_finance_nem_pluggy(client):
    # OPEN_FINANCE_ENABLED está off e nenhuma variável PLUGGY_* existe:
    # a rota responde (não 404), /api/open-finance/* segue fora do ar e
    # /api/features não muda.
    resposta = _post(client, _OFX.encode(), "fatura.ofx", "application/ofx")
    assert resposta.status_code == 200

    assert client.get("/api/open-finance/cards").status_code == 404
    assert client.get("/api/features").json() == {"open_finance": False}


def test_sem_token_da_401(app_fatura):
    from dependencies import get_current_user_id

    app_fatura.dependency_overrides.pop(get_current_user_id, None)
    client = TestClient(app_fatura)
    resposta = client.post(
        "/api/faturas/ler",
        files={"arquivo": ("fatura.ofx", _OFX.encode(), "application/ofx")},
    )
    assert resposta.status_code == 401


# ------------------------------------------------- efeitos colaterais


def test_nada_e_gravado_e_storage_nunca_chamado(client, gemini, tmp_path):
    from database import Base, get_db
    import models  # noqa: F401  (registra as tabelas no metadata)

    engine = create_engine(f"sqlite:///{tmp_path}/fatura.db")
    Base.metadata.create_all(engine)
    session = Session(engine)

    def _contagens():
        return {
            t: session.execute(text(f"SELECT COUNT(*) FROM {t}")).scalar()
            for t in Base.metadata.tables
        }

    app = client.app
    app.dependency_overrides[get_db] = lambda: iter([session])
    try:
        antes = _contagens()
        with patch(
            "services.storage_service.salvar_comprovante"
        ) as salvar, patch(
            "services.storage_service.remover_comprovante"
        ) as remover:
            resposta = _post(client, _pdf(), "fatura.pdf", "application/pdf")
        assert resposta.status_code == 200
        assert _contagens() == antes
        salvar.assert_not_called()
        remover.assert_not_called()
    finally:
        session.close()
        engine.dispose()


def test_log_nao_contem_descricao_valor_nem_senha(client, monkeypatch, caplog):
    falso = _ClienteGeminiFalso(
        _resposta_gemini(
            _fatura_extraida(
                compras=[
                    CompraExtraida(
                        data="2026-10-01",
                        descricao="COMPRA-SECRETA-XYZ",
                        valor=4242.42,
                    )
                ],
                total_fatura=4242.42,
            )
        )
    )
    monkeypatch.setattr(fatura_ia_service, "_client", falso)
    caplog.set_level(logging.INFO)

    resposta = _post(
        client,
        _pdf_com_senha("senha-ultra-secreta-777"),
        "fatura.pdf",
        "application/pdf",
        senha="senha-ultra-secreta-777",
    )
    assert resposta.status_code == 200
    assert "COMPRA-SECRETA-XYZ" not in caplog.text
    assert "4242.42" not in caplog.text
    assert "senha-ultra-secreta-777" not in caplog.text

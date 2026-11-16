"""Teto diário de leituras por IA por usuário (`services/limite_ia.py`).

O Gemini é sempre substituído por um falso (`ocr_service` e o `_client` do
`fatura_ia_service`): nenhum teste faz chamada real. O slowapi fica
desligado porque o limite dele é por IP e tornaria a suíte dependente do
total de requisições.
"""

import importlib
import io
import sys
from datetime import date
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from PIL import Image
from reportlab.lib.pdfencrypt import StandardEncryption
from reportlab.pdfgen import canvas

from enums.categoria_enum import Categoria
from services import fatura_ia_service, limite_ia, ocr_service
from services.fatura_ia_service import CompraExtraida, FaturaExtraida

USER_A = "user-a"
USER_B = "user-b"

# A fixture `gemini` troca `extrair_gasto_da_imagem` por um dublê; os testes
# da devolução de cota restauram a função de verdade e derrubam só o client.
_extrair_gasto_real = ocr_service.extrair_gasto_da_imagem


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


# PNG mínimo: o `filetype` só olha os bytes iniciais.
_PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + b"\x00" * 32


def _png_valido() -> bytes:
    """PNG de verdade: passa também pelo `_preprocessar_imagem` do OCR."""
    buffer = io.BytesIO()
    Image.new("RGB", (8, 8), "white").save(buffer, format="PNG")
    return buffer.getvalue()

_OFX = """OFXHEADER:100
DATA:OFXSGML
VERSION:102
<OFX>
<SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS><DTSERVER>20261020<LANGUAGE>POR<FI><ORG>Banco Teste</FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>BRL<CCACCTFROM><ACCTID>1234</CCACCTFROM>
<BANKTRANLIST><DTSTART>20260911000000<DTEND>20261010000000
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261001000000<TRNAMT>-100.00<FITID>t1<MEMO>SUPERMERCADO X</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-100.00<DTASOF>20261020000000</LEDGERBAL>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
"""

_CSV = "Data;Descrição;Valor\n01/10/2026;Supermercado;100,00\n"


class _ClienteGeminiFalso:
    """Imita `_client.models.generate_content` do google-genai.

    `falhas` derruba as primeiras chamadas (Gemini fora do ar)."""

    def __init__(self, resposta, falhas: int = 0):
        self.resposta = resposta
        self.falhas = falhas
        self.chamadas = []
        self.models = self

    def generate_content(self, **kwargs):
        self.chamadas.append(kwargs)
        if self.falhas:
            self.falhas -= 1
            raise RuntimeError("Gemini fora do ar")
        return self.resposta


def _resposta_gemini() -> SimpleNamespace:
    fatura = FaturaExtraida(
        emissor="Banco Teste",
        final_cartao="1234 5678",
        fechamento="2026-10-10",
        vencimento="2026-10-20",
        total_fatura=100.0,
        compras=[
            CompraExtraida(data="2026-10-01", descricao="SUPERMERCADO", valor=100.0),
        ],
    )
    return SimpleNamespace(
        parsed=fatura,
        text="",
        candidates=[SimpleNamespace(finish_reason="STOP")],
        usage_metadata=SimpleNamespace(prompt_token_count=1, candidates_token_count=1),
    )


def _resposta_ocr() -> SimpleNamespace:
    return SimpleNamespace(
        parsed=ocr_service.GastoExtraido(
            titulo="Padaria", valor=10.0, categoria=Categoria.ALIMENTACAO
        ),
        text="",
        candidates=[SimpleNamespace(finish_reason="STOP")],
        usage_metadata=SimpleNamespace(prompt_token_count=1, candidates_token_count=1),
    )


def _comprovante(client: TestClient, conteudo: bytes = _PNG):
    return client.post(
        "/gastos/extrair",
        files={"imagem": ("nota.png", conteudo, "image/png")},
    )


def _fatura(client: TestClient, conteudo: bytes, nome: str, content_type: str, **form):
    return client.post(
        "/api/faturas/ler",
        files={"arquivo": (nome, conteudo, content_type)},
        data={k: v for k, v in form.items() if v is not None},
    )


def _fatura_pdf(client: TestClient):
    return _fatura(client, _pdf(), "fatura.pdf", "application/pdf")


# ---------------------------------------------------------------- fixtures


@pytest.fixture
def app_limite(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    monkeypatch.delenv("IA_LIMITE_DIARIO_COMPROVANTE", raising=False)
    monkeypatch.delenv("IA_LIMITE_DIARIO_FATURA", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app

    import limiter as limiter_module

    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    from dependencies import get_current_user_id

    app.dependency_overrides[get_current_user_id] = lambda: USER_A

    limite_ia._contadores.clear()
    try:
        yield app
    finally:
        limite_ia._contadores.clear()
        app.dependency_overrides.clear()


@pytest.fixture
def client(app_limite):
    return TestClient(app_limite)


@pytest.fixture
def gemini(app_limite, monkeypatch):
    """Instala os dois Geminis falsos e devolve o contador de chamadas."""
    chamadas = {"comprovante": 0}
    falso_fatura = _ClienteGeminiFalso(_resposta_gemini())

    def _extrair_falso(conteudo):
        chamadas["comprovante"] += 1
        return {"titulo": "Padaria", "valor": 10.0, "categoria": "ALIMENTACAO"}

    monkeypatch.setattr(ocr_service, "extrair_gasto_da_imagem", _extrair_falso)
    monkeypatch.setattr(fatura_ia_service, "_client", falso_fatura)
    return chamadas, falso_fatura


def _como(app_limite, user_id: str) -> TestClient:
    from dependencies import get_current_user_id

    app_limite.dependency_overrides[get_current_user_id] = lambda: user_id
    return TestClient(app_limite)


# ------------------------------------------------------------ comprovante


def test_comprovante_n_mais_um_do_dia_da_429(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "2")
    chamadas, _ = gemini

    assert _comprovante(client).status_code == 200
    assert _comprovante(client).status_code == 200

    resposta = _comprovante(client)
    assert resposta.status_code == 429
    corpo = resposta.json()
    assert corpo["error"] == "daily_ai_limit"
    assert corpo["request_id"]
    # O pedido recusado não chega à IA nem gasta cota.
    assert chamadas["comprovante"] == 2

    assert _comprovante(client).status_code == 429
    assert chamadas["comprovante"] == 2


def test_fatura_pdf_n_mais_um_do_dia_da_429(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "2")
    _, falso_fatura = gemini

    assert _fatura_pdf(client).status_code == 200
    assert _fatura_pdf(client).status_code == 200

    resposta = _fatura_pdf(client)
    assert resposta.status_code == 429
    corpo = resposta.json()
    assert corpo["error"] == "daily_ai_limit"
    assert corpo["request_id"]
    assert len(falso_fatura.chamadas) == 2


def test_outro_usuario_nao_e_afetado(app_limite, client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "1")
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "1")

    assert _comprovante(client).status_code == 200
    assert _comprovante(client).status_code == 429
    # A cota é por (usuário, tipo): a de fatura continua intacta.
    assert _fatura_pdf(client).status_code == 200
    assert _fatura_pdf(client).status_code == 429

    outro = _como(app_limite, USER_B)
    assert _comprovante(outro).status_code == 200
    assert _fatura_pdf(outro).status_code == 200


def test_dia_seguinte_zera(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "2")
    hoje = date(2026, 11, 15)
    amanha = date(2026, 11, 16)

    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    with pytest.raises(HTTPException) as erro:
        limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    assert erro.value.status_code == 429

    # A virada da data UTC recomeça a contagem; a cota de outro tipo é
    # independente da de comprovante.
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=amanha)
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=amanha)
    limite_ia.contar(USER_A, limite_ia.FATURA, hoje=hoje)


def test_virada_do_dia_descarta_contadores_velhos(app_limite, monkeypatch):
    """Chaves de outra data são apagadas no `contar`: memória não cresce."""
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "2")
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "2")
    hoje = date(2026, 11, 15)
    amanha = date(2026, 11, 16)

    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    limite_ia.contar(USER_B, limite_ia.FATURA, hoje=hoje)

    # O primeiro pedido de D+1 joga fora todas as chaves de D.
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=amanha)
    assert set(limite_ia._contadores) == {(USER_A, limite_ia.COMPROVANTE, amanha)}

    # O teto de D+1 continua valendo.
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=amanha)
    with pytest.raises(HTTPException) as erro:
        limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=amanha)
    assert erro.value.status_code == 429


def test_zero_desliga(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "0")
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "0")

    for _ in range(5):
        assert _comprovante(client).status_code == 200
        assert _fatura_pdf(client).status_code == 200


def test_ofx_e_csv_nao_contam(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "1")

    for _ in range(3):
        assert (
            _fatura(client, _OFX.encode(), "fatura.ofx", "application/ofx").status_code
            == 200
        )
        assert (
            _fatura(client, _CSV.encode("utf-8"), "fatura.csv", "text/csv").status_code
            == 200
        )

    # A cota do tipo `fatura` continua intacta: 1 PDF passa, o 2º estoura.
    assert _fatura_pdf(client).status_code == 200
    assert _fatura_pdf(client).status_code == 429


def test_arquivo_recusado_na_validacao_nao_conta(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "1")
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "1")

    # Comprovante: arquivo que nem é imagem é recusado (400) antes do teto.
    assert (
        client.post(
            "/gastos/extrair",
            files={"imagem": ("nota.txt", b"texto", "text/plain")},
        ).status_code
        == 400
    )
    assert _comprovante(client).status_code == 200
    assert _comprovante(client).status_code == 429

    # Fatura: imagem recusada no `ler_upload` e PDF com senha errada no
    # `desproteger_pdf` não gastam cota.
    assert (
        _fatura(client, _PNG, "foto.png", "image/png").status_code == 400
    )
    assert (
        _fatura(
            client,
            _pdf_com_senha("1234"),
            "fatura.pdf",
            "application/pdf",
            senha="errada",
        ).status_code
        == 422
    )
    assert _fatura_pdf(client).status_code == 200
    assert _fatura_pdf(client).status_code == 429


# -------------------------------------------------------- devolução da cota


def test_falha_do_gemini_devolve_a_vaga_comprovante(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "1")
    falso = _ClienteGeminiFalso(_resposta_ocr(), falhas=1)
    monkeypatch.setattr(ocr_service, "_client", falso)
    monkeypatch.setattr(
        ocr_service, "extrair_gasto_da_imagem", _extrair_gasto_real
    )

    # Gemini fora do ar: 500 como antes, mas a vaga volta.
    assert _comprovante(client, _png_valido()).status_code == 500
    assert _comprovante(client, _png_valido()).status_code == 200
    assert _comprovante(client, _png_valido()).status_code == 429
    assert len(falso.chamadas) == 2


def test_falha_do_gemini_devolve_a_vaga_fatura(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "1")
    falso = _ClienteGeminiFalso(_resposta_gemini(), falhas=1)
    monkeypatch.setattr(fatura_ia_service, "_client", falso)

    assert _fatura_pdf(client).status_code == 500
    assert _fatura_pdf(client).status_code == 200
    assert _fatura_pdf(client).status_code == 429
    assert len(falso.chamadas) == 2


def test_sem_chave_nao_conta(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "1")
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "1")
    monkeypatch.setattr(ocr_service, "_client", None)
    monkeypatch.setattr(fatura_ia_service, "_client", None)
    monkeypatch.setattr(
        ocr_service, "extrair_gasto_da_imagem", _extrair_gasto_real
    )

    # Mesmos status de antes (422 no comprovante, 503 na fatura), sem gastar vaga.
    assert _comprovante(client, _png_valido()).status_code == 422
    assert _fatura_pdf(client).status_code == 503

    monkeypatch.setattr(
        ocr_service, "_client", _ClienteGeminiFalso(_resposta_ocr())
    )
    monkeypatch.setattr(
        fatura_ia_service, "_client", _ClienteGeminiFalso(_resposta_gemini())
    )
    assert _comprovante(client, _png_valido()).status_code == 200
    assert _fatura_pdf(client).status_code == 200
    assert _comprovante(client, _png_valido()).status_code == 429
    assert _fatura_pdf(client).status_code == 429


def test_resposta_inesperada_conta(client, gemini, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "1")
    monkeypatch.setenv("IA_LIMITE_DIARIO_FATURA", "1")
    monkeypatch.setattr(
        ocr_service, "extrair_gasto_da_imagem", _extrair_gasto_real
    )
    lixo = SimpleNamespace(
        parsed=None, text="isto nao e json", candidates=[], usage_metadata=None
    )
    monkeypatch.setattr(ocr_service, "_client", _ClienteGeminiFalso(lixo))
    monkeypatch.setattr(fatura_ia_service, "_client", _ClienteGeminiFalso(lixo))

    # O Gemini respondeu (mesmo que mal): a cota ficou gasta.
    assert _comprovante(client, _png_valido()).status_code == 422
    assert _fatura_pdf(client).status_code == 422
    assert _comprovante(client, _png_valido()).status_code == 429
    assert _fatura_pdf(client).status_code == 429


def test_devolver_nao_fica_negativo(app_limite, monkeypatch):
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "2")
    hoje = date(2026, 11, 16)
    chave = (USER_A, limite_ia.COMPROVANTE, hoje)

    # Sem ter contado, não cria chave nem desce.
    limite_ia.devolver(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    assert chave not in limite_ia._contadores

    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    limite_ia.devolver(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    limite_ia.devolver(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    assert limite_ia._contadores[chave] == 0

    # O par (contar, devolver) não comeu o teto: ainda cabem 2 no dia.
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    with pytest.raises(HTTPException) as erro:
        limite_ia.contar(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    assert erro.value.status_code == 429

    # Com o teto desligado o `contar` não conta: `devolver` é no-op.
    monkeypatch.setenv("IA_LIMITE_DIARIO_COMPROVANTE", "0")
    limite_ia.devolver(USER_A, limite_ia.COMPROVANTE, hoje=hoje)
    assert limite_ia._contadores[chave] == 2

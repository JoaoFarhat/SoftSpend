"""O `ciclo_id` do POST /api/faturas/ler é conferido antes de ler o arquivo.

Antes o ciclo só era checado no `marcar_previa`, depois do upload, do
`limite_ia.contar` e da chamada ao Gemini: uma viagem apagada em outro
aparelho (ou de outro usuário) gastava 1 das 10 leituras do dia e uma
chamada paga para terminar em 404. Agora a rota responde 404 no começo e
o `marcar_previa` segue como segunda barreira. O Gemini é substituído
(`_client` do `fatura_ia_service` e espião no `ler_fatura_pdf`): nenhum
teste faz chamada real.
"""

import importlib
import io
import sys
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from reportlab.pdfgen import canvas
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from services import fatura_ia_service, limite_ia
from services.fatura_arquivo_service import FaturaBruta
from services.fatura_ia_service import CompraExtraida, FaturaExtraida

USER_A = "user-1"
USER_B = "user-2"
INICIO = date(2026, 10, 1)
FIM = date(2026, 10, 7)


# ---------------------------------------------------------------- helpers


def _pdf() -> bytes:
    buffer = io.BytesIO()
    c = canvas.Canvas(buffer)
    c.drawString(72, 720, "FATURA")
    c.showPage()
    c.save()
    return buffer.getvalue()


_CSV = "Data;Descrição;Valor\n01/10/2026;Supermercado;100,00\n"


class _ClienteGeminiFalso:
    """Imita `_client.models.generate_content` do google-genai."""

    def __init__(self, resposta):
        self.resposta = resposta
        self.chamadas = []
        self.models = self

    def generate_content(self, **kwargs):
        self.chamadas.append(kwargs)
        return self.resposta


def _resposta_gemini() -> SimpleNamespace:
    fatura = FaturaExtraida(
        emissor="Banco Teste",
        vencimento="2026-10-20",
        compras=[
            CompraExtraida(
                data="2026-10-01", descricao="SUPERMERCADO", valor=100.0
            ),
        ],
    )
    return SimpleNamespace(
        parsed=fatura,
        text="",
        candidates=[SimpleNamespace(finish_reason="STOP")],
        usage_metadata=SimpleNamespace(
            prompt_token_count=1, candidates_token_count=1
        ),
    )


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
    monkeypatch.delenv("IA_LIMITE_DIARIO_FATURA", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/fatura_ciclo_antes.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add_all(
        [
            models.User(
                id=USER_A, nome="A", username="a", email="a@e.com",
                senha_hash="hash",
            ),
            models.User(
                id=USER_B, nome="B", username="b", email="b@e.com",
                senha_hash="hash",
            ),
        ]
    )
    session.commit()

    def override_db():
        yield session

    app.dependency_overrides[get_db] = override_db
    limite_ia._contadores.clear()
    try:
        yield _Ambiente(app, session)
    finally:
        limite_ia._contadores.clear()
        app.dependency_overrides.clear()
        session.close()
        engine.dispose()


@pytest.fixture
def ia_espiao(ambiente, monkeypatch):
    """Gemini falso + espião no `ler_fatura_pdf`, que anota cada chamada."""
    falso = _ClienteGeminiFalso(_resposta_gemini())
    monkeypatch.setattr(fatura_ia_service, "_client", falso)
    chamadas = []

    def _espiao(pdf_bytes):
        chamadas.append(pdf_bytes)
        return FaturaBruta(emissor="Banco Teste")

    monkeypatch.setattr(fatura_ia_service, "ler_fatura_pdf", _espiao)
    return falso, chamadas


def _ciclo(session, user_id=USER_A):
    import models

    ciclo = models.Ciclo(id_usuario=user_id, titulo="Viagem")
    session.add(ciclo)
    session.flush()
    dias = [
        models.Dia(
            ciclo_id=ciclo.id,
            data=datetime.combine(
                INICIO + timedelta(days=i), time.min, tzinfo=timezone.utc
            ),
            saldo=Decimal("100.00"),
        )
        for i in range((FIM - INICIO).days + 1)
    ]
    session.add_all(dias)
    session.flush()
    return ciclo, dias


def _ler(client, conteudo: bytes, nome: str, content_type: str, **form):
    return client.post(
        "/api/faturas/ler",
        files={"arquivo": (nome, conteudo, content_type)},
        data={k: str(v) for k, v in form.items() if v is not None},
    )


def _usado_fatura(user_id: str) -> int:
    return limite_ia._contadores.get(
        (user_id, limite_ia.FATURA, limite_ia._hoje()), 0
    )


# ------------------------------------------------------------------ testes


def test_pdf_ciclo_de_outro_usuario_da_404_antes_da_ia(ambiente, ia_espiao):
    ciclo_b, _ = _ciclo(ambiente.session, user_id=USER_B)
    falso, chamadas = ia_espiao

    resposta = _ler(
        ambiente.como(USER_A),
        _pdf(),
        "fatura.pdf",
        "application/pdf",
        ciclo_id=ciclo_b.id,
    )

    assert resposta.status_code == 404
    assert resposta.json()["error"] == "Ciclo não encontrado"
    # O ciclo foi recusado antes do upload, do teto diário e do Gemini.
    assert chamadas == []
    assert falso.chamadas == []
    assert _usado_fatura(USER_A) == 0


def test_pdf_ciclo_inexistente_da_404_antes_da_ia(ambiente, ia_espiao):
    falso, chamadas = ia_espiao

    resposta = _ler(
        ambiente.como(USER_A),
        _pdf(),
        "fatura.pdf",
        "application/pdf",
        ciclo_id=999999,
    )

    assert resposta.status_code == 404
    assert resposta.json()["error"] == "Ciclo não encontrado"
    assert chamadas == []
    assert falso.chamadas == []
    assert _usado_fatura(USER_A) == 0


def test_csv_com_ciclo_valido_devolve_previa_com_dia_id(ambiente, ia_espiao):
    ciclo, dias = _ciclo(ambiente.session)

    resposta = _ler(
        ambiente.como(USER_A),
        _CSV.encode("utf-8"),
        "fatura.csv",
        "text/csv",
        ciclo_id=ciclo.id,
    )

    assert resposta.status_code == 200
    compra = resposta.json()["compras"][0]
    assert compra["dentro_da_viagem"] is True
    assert compra["dia_id"] == dias[0].id

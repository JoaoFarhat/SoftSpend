"""Escapes do export de gastos (PDF e CSV).

O ReportLab le o texto do `Paragraph` como marcacao: um `<` ou `&` no titulo
quebrava `gerar_pdf` e a rota devolvia 500. No CSV, texto que comeca com `=`,
`+`, `-`, `@` (tab ou retorno tambem) vira formula ao abrir no Excel e leva `'`
na frente.

Mesmo padrao de `test_core_api.py`: SQLite em `tmp_path` e
`dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib
import sys
from datetime import datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

USER_A = "user-a"


class _Ambiente:
    def __init__(self, app, session):
        self.app = app
        self.session = session

    def como(self, user_id: str, **kwargs) -> TestClient:
        from dependencies import get_current_user_id

        self.app.dependency_overrides[get_current_user_id] = lambda: user_id
        return TestClient(self.app, **kwargs)


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
    monkeypatch.delenv("BILLING_ENFORCEMENT", raising=False)
    sys.modules.pop("main", None)
    app = importlib.import_module("main").app
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/export.db")
    Base.metadata.create_all(engine)
    session = Session(engine)
    session.add(
        models.User(
            id=USER_A,
            nome="A",
            username="user_a",
            email="a@example.com",
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


def _ciclo_dia_gasto(client, titulo_ciclo, titulo_gasto, valor_gasto="25.50"):
    ciclo = client.post(
        "/ciclos",
        json={
            "client_id": "ciclo-1",
            "valor_total": "700.00",
            "periodo": "01/11/2026 a 07/11/2026",
            "diaria": "100.00",
            "titulo": titulo_ciclo,
        },
    ).json()
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={"client_id": "dia-1", "data": "2026-11-01T00:00:00Z"},
    ).json()
    gasto = client.post(
        f"/dias/{dia['id']}/gastos",
        json={
            "client_id": "gasto-1",
            "titulo": titulo_gasto,
            "valor": valor_gasto,
            "categoria": "ALIMENTACAO",
        },
    ).json()
    return ciclo, dia, gasto


def test_gerar_pdf_com_titulo_contendo_menor_que():
    """`gerar_pdf` nao pode quebrar com `<`/`&` vindo do banco."""
    import models
    from enums.categoria_enum import Categoria
    from services import export_service

    ciclo = models.Ciclo(
        titulo="Ida <SP>",
        periodo="01/11/2026 a 07/11/2026",
        valor_total=Decimal("700.00"),
        gasto_total=Decimal("25.50"),
        diaria=Decimal("100.00"),
    )
    dia = models.Dia(
        data=datetime(2026, 11, 1), saldo=Decimal("74.50"), ciclo=ciclo
    )
    models.Gasto(
        titulo="Bar <Centro> & Cia",
        valor=Decimal("25.50"),
        categoria=Categoria.ALIMENTACAO,
        dia=dia,
    )

    pdf = export_service.gerar_pdf(ciclo)

    assert pdf.startswith(b"%PDF")


def test_export_pdf_pela_rota_com_titulo_contendo_menor_que(ambiente):
    client = ambiente.como(USER_A)
    ciclo, _, _ = _ciclo_dia_gasto(client, "Ida <SP>", "Bar <Centro> & Cia")

    response = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "pdf"}
    )

    assert response.status_code == 200
    assert response.headers["Content-Type"] == "application/pdf"
    assert response.content.startswith(b"%PDF")


def test_csv_protege_titulo_contra_formula_e_mantem_saldo_negativo(ambiente):
    client = ambiente.como(USER_A)
    # 110 de gasto numa diaria de 100 deixa o saldo em -10.00.
    ciclo, _, _ = _ciclo_dia_gasto(client, "Viagem", "=1+1", "110.00")

    response = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert response.status_code == 200
    texto = response.content.decode("utf-8-sig")
    assert "'=1+1" in texto
    assert "-10.00" in texto
    # O titulo do ciclo e os valores numericos nao ganham o prefixo.
    assert "Ciclo;Viagem" in texto

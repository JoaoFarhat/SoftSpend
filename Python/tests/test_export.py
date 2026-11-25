"""Escapes do export de gastos (PDF e CSV).

O ReportLab le o texto do `Paragraph` como marcacao: um `<` ou `&` no titulo
quebrava `gerar_pdf` e a rota devolvia 500. No CSV, texto que comeca com `=`,
`+`, `-`, `@` (tab ou retorno tambem) vira formula ao abrir no Excel e leva `'`
na frente.

A hora do "gerado em" do PDF sai no fuso de Brasilia (UTC-3 fixo), porque a
EC2 roda em UTC e o `datetime.now()` marcava a hora errada (e o dia seguinte
depois das 21:00).

Mesmo padrao de `test_core_api.py`: SQLite em `tmp_path` e
`dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib
import re
import sys
from datetime import datetime, timedelta, timezone
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


def test_export_pdf_com_link_de_comprovante_contendo_e_comercial(ambiente, monkeypatch):
    """URL pre-assinada do S3 tem `&`; sem escape o Paragraph quebrava (500)."""
    import models
    from services import storage_service

    client = ambiente.como(USER_A)
    ciclo, _, gasto = _ciclo_dia_gasto(client, "Viagem", "Bar")

    gasto_db = ambiente.session.get(models.Gasto, gasto["id"])
    gasto_db.comprovante_key = "comprovantes/user-a/1-abcdef.jpg"
    ambiente.session.commit()

    url = "https://bucket.example/c?X-Amz-A=1&X-Amz-B=2"
    monkeypatch.setattr(storage_service, "url_do_comprovante", lambda key: url)

    response = client.get(
        f"/ciclos/{ciclo['id']}/export",
        params={"formato": "pdf", "comprovantes": "link"},
    )

    assert response.status_code == 200
    assert response.content.startswith(b"%PDF")

    # A anotacao de link sai como `/URI (url)` numa string literal do PDF;
    # a URL do teste nao tem `(`, `)` nem `\`, que seriam escapados.
    uris = re.findall(rb"/URI \((.*?)\)", response.content)
    assert uris, "o PDF nao tem nenhuma anotacao /URI"
    assert url.encode() in uris


def test_csv_protege_titulo_contra_formula_e_mantem_saldo_negativo(ambiente):
    import models
    from enums.categoria_enum import Categoria

    client = ambiente.como(USER_A)
    # 113 de gasto numa diaria de 100 deixa o saldo em -13.00.
    ciclo, dia, _ = _ciclo_dia_gasto(client, "Viagem", "=1+1", "110.00")
    # Outros inicios que o Excel le como formula ao abrir o CSV.
    for indice, titulo in enumerate(("+1+1", "@SUM(1)"), start=2):
        criado = client.post(
            f"/dias/{dia['id']}/gastos",
            json={
                "client_id": f"gasto-{indice}",
                "titulo": titulo,
                "valor": "1.00",
                "categoria": "OUTROS",
            },
        )
        assert criado.status_code == 200, criado.text

    # Registro gravado antes do `GastoRequest.nao_somente_espacos` aparar as
    # pontas do titulo: tab na frente nao entra mais pela API, so existe no
    # banco. A protecao do CSV continua valendo para ele.
    dia_db = ambiente.session.get(models.Dia, dia["id"])
    ciclo_db = ambiente.session.get(models.Ciclo, ciclo["id"])
    ambiente.session.add(
        models.Gasto(
            titulo="\tcmd",
            valor=Decimal("1.00"),
            categoria=Categoria.OUTROS,
            dia=dia_db,
        )
    )
    dia_db.saldo -= Decimal("1.00")
    ciclo_db.gasto_total += Decimal("1.00")
    ambiente.session.commit()

    response = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert response.status_code == 200
    texto = response.content.decode("utf-8-sig")
    for titulo in ("=1+1", "+1+1", "@SUM(1)", "\tcmd"):
        assert f"'{titulo}" in texto
    assert "-13.00" in texto
    # O titulo do ciclo e os valores numericos nao ganham o prefixo.
    assert "Ciclo;Viagem" in texto


@pytest.mark.parametrize(
    "agora_utc,esperado",
    [
        # 23:40 UTC ainda sao 20:40 do mesmo dia em Brasilia.
        (datetime(2026, 11, 25, 23, 40, tzinfo=timezone.utc), (25, 20, 40)),
        # Depois das 21:00 em Brasilia o UTC ja virou o dia: 01:30 UTC do
        # dia 26 e 22:30 do dia 25, nao o dia seguinte.
        (datetime(2026, 11, 26, 1, 30, tzinfo=timezone.utc), (25, 22, 30)),
    ],
)
def test_agora_brasil_converte_do_utc_do_servidor(monkeypatch, agora_utc, esperado):
    """A EC2 roda em UTC; `_agora_brasil` converte para o fuso do relatorio."""
    from services import export_service

    class _DatetimeCongelado:
        @staticmethod
        def now(tz=None):
            return agora_utc

    monkeypatch.setattr(export_service, "datetime", _DatetimeCongelado)

    agora = export_service._agora_brasil()

    assert agora.tzinfo == export_service.FUSO_BRASIL
    assert agora.utcoffset() == timedelta(hours=-3)
    assert (agora.day, agora.hour, agora.minute) == esperado


def test_gerar_pdf_escreve_gerado_em_na_hora_de_brasilia():
    """O 'gerado em' sai no fuso de Brasilia, nao no UTC do servidor."""
    import pypdfium2 as pdfium
    import models
    from services import export_service
    from services.pdfium_seguro import trava_pdfium

    ciclo = models.Ciclo(
        titulo="Viagem",
        periodo="01/11/2026 a 07/11/2026",
        valor_total=Decimal("700.00"),
        gasto_total=Decimal("0.00"),
        diaria=Decimal("100.00"),
    )
    agora = datetime(2026, 11, 25, 20, 40, tzinfo=export_service.FUSO_BRASIL)

    pdf = export_service.gerar_pdf(ciclo, agora=agora)

    # O pypdfium2 nao e seguro entre threads: toda chamada fica na trava.
    with trava_pdfium:
        documento = pdfium.PdfDocument(pdf)
        try:
            texto = "".join(
                documento[i].get_textpage().get_text_bounded()
                for i in range(len(documento))
            )
        finally:
            documento.close()

    assert "gerado em 25/11/2026 20:40" in texto

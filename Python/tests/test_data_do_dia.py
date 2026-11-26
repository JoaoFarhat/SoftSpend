"""Data do dia sem depender do fuso (spec `docs/data-do-dia.md`, tarefa D1).

O app grava `dias.data` como a meia-noite local do aparelho em UTC; ler o dia
de calendário dela em UTC erra em um dia para todo fuso a leste de Greenwich.
A coluna `dias.data_dia` passa a guardar a data de calendário que o app manda
em `data_local`; para linhas antigas e apps antigos, a heurística da hora UTC
(≥ 11h → fuso a leste, dia UTC seguinte) aproxima o dia.

Mesmo padrão de `test_core_api.py`: SQLite em `tmp_path` e
`dependency_overrides` para `get_db` e `get_current_user_id`.
"""

import importlib.util
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text

import models
from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    _ciclo_payload,
    _dia_payload,
    _gasto_payload,
    ambiente,
)

_CAMINHO_MIGRACAO = (
    Path(__file__).resolve().parents[1]
    / "alembic"
    / "versions"
    / "b8e4d2f6a1c3_add_data_dia_to_dias.py"
)


def _criar_ciclo(client) -> dict:
    resposta = client.post("/ciclos", json=_ciclo_payload())
    assert resposta.status_code == 200
    return resposta.json()


def _executar_migracao(engine, funcao: str):
    spec = importlib.util.spec_from_file_location(
        "b8e4d2f6a1c3_migracao", _CAMINHO_MIGRACAO
    )
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    assert modulo.down_revision == "a7c3e9f1b5d2"
    with engine.connect() as conexao:
        contexto = MigrationContext.configure(conexao)
        with Operations.context(contexto):
            getattr(modulo, funcao)()
        conexao.commit()


# ------------------------------------------------------------ heurística


@pytest.mark.parametrize(
    "instante,esperado",
    [
        # UTC+0: meia-noite UTC é o próprio dia.
        (datetime(2026, 7, 21, 0, 0, tzinfo=timezone.utc), date(2026, 7, 21)),
        # Brasil (UTC-3): meia-noite local vira 03:00Z do mesmo dia.
        (datetime(2026, 7, 21, 3, 0, tzinfo=timezone.utc), date(2026, 7, 21)),
        # Havaí (UTC-10): 10:00Z do dia anterior — abaixo do corte, mesmo dia.
        (datetime(2026, 7, 20, 10, 0, tzinfo=timezone.utc), date(2026, 7, 20)),
        # Nova Zelândia (UTC+12): 11:00Z do dia anterior — no corte, dia seguinte.
        (datetime(2026, 7, 20, 11, 0, tzinfo=timezone.utc), date(2026, 7, 21)),
        # Paris (UTC+2): 22:00Z do dia anterior.
        (datetime(2026, 7, 20, 22, 0, tzinfo=timezone.utc), date(2026, 7, 21)),
        # Índia (UTC+5:30): 18:30Z do dia anterior.
        (datetime(2026, 7, 20, 18, 30, tzinfo=timezone.utc), date(2026, 7, 21)),
    ],
)
def test_dia_de_calendario_pela_hora_utc(instante, esperado):
    from services.dia_calendario import dia_de_calendario

    assert dia_de_calendario(instante) == esperado


def test_dia_de_calendario_aceita_instante_sem_fuso():
    """Linha lida de coluna naive (SQLite/MySQL) é tratada como UTC."""
    from services.dia_calendario import dia_de_calendario

    assert dia_de_calendario(datetime(2026, 7, 20, 22, 0)) == date(2026, 7, 21)


def test_data_do_dia_prefere_data_dia_e_cai_no_fallback():
    from services.dia_calendario import data_do_dia

    dia = models.Dia(data=datetime(2026, 7, 20, 22, 0), data_dia=date(2026, 7, 25))
    assert data_do_dia(dia) == date(2026, 7, 25)

    dia.data_dia = None
    assert data_do_dia(dia) == date(2026, 7, 21)

    dia.data = None
    assert data_do_dia(dia) is None
    assert data_do_dia(None) is None


# ------------------------------------------------------------ entrada


def test_post_dia_com_data_local_grava_data_dia_e_devolve_na_resposta(ambiente):  # noqa: F811
    """`data_local` manda mesmo em desacordo com o instante `data` — que
    continua gravado como veio, para os apps antigos."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-20T22:00:00Z",
            "data_local": "2026-07-25",
        },
    )

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["data_local"] == "2026-07-25"
    assert corpo["data"] == "2026-07-20T22:00:00Z"

    dia = ambiente.session.get(models.Dia, corpo["id"])
    assert dia.data_dia == date(2026, 7, 25)


def test_post_dia_sem_data_local_usa_heuristica_do_utc(ambiente):  # noqa: F811
    """App antigo manda só o instante: 22:00Z do dia 20 é meia-noite de 21/07
    num fuso a leste de Greenwich."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={"client_id": "dia-1", "data": "2026-07-20T22:00:00Z"},
    )

    assert resposta.status_code == 200
    assert resposta.json()["data_local"] == "2026-07-21"
    dia = ambiente.session.get(models.Dia, resposta.json()["id"])
    assert dia.data_dia == date(2026, 7, 21)


def test_lote_misto_com_e_sem_data_local(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            {
                "client_id": "dia-novo",
                "data": "2026-07-20T22:00:00Z",
                "data_local": "2026-07-21",
            },
            {"client_id": "dia-antigo", "data": "2026-07-21T22:00:00Z"},
        ],
    )

    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo[0]["data_local"] == "2026-07-21"
    assert corpo[1]["data_local"] == "2026-07-22"
    dias = ambiente.session.query(models.Dia).order_by(models.Dia.id).all()
    assert dias[0].data_dia == date(2026, 7, 21)
    assert dias[1].data_dia == date(2026, 7, 22)


def test_reenvio_devolve_o_existente_sem_recalcular_data_dia(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    primeiro = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-20T22:00:00Z",
            "data_local": "2026-07-21",
        },
    ).json()
    repetido = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-08-20T22:00:00Z",
            "data_local": "2026-08-22",
        },
    ).json()

    assert repetido["id"] == primeiro["id"]
    assert repetido["data_local"] == "2026-07-21"


def test_dia_sem_data_dia_responde_data_local_pelo_fallback(ambiente):  # noqa: F811
    """Linha que sobrou sem `data_dia` (não deveria depois do backfill) ainda
    devolve `data_local` calculado pela regra da seção 4."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload("dia-1", "2026-07-20T22:00:00Z"),
    ).json()

    dia_db = ambiente.session.get(models.Dia, dia["id"])
    dia_db.data_dia = None
    ambiente.session.commit()

    resposta = client.get(f"/ciclos/{ciclo['id']}/dias")
    assert resposta.status_code == 200
    assert resposta.json()[0]["data_local"] == "2026-07-21"


def test_data_local_fora_do_intervalo_vira_422(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-20T22:00:00Z",
            "data_local": "2010-01-01",
        },
    )

    assert resposta.status_code == 422


# ------------------------------------------------------------ uso interno


def _viagem_em_paris(client, session):
    """Viagem de 21 a 23/07 vista de um aparelho em UTC+2, como um app antigo
    a gravaria: meia-noite local = 22:00Z do dia anterior."""
    ciclo = _criar_ciclo(client)
    dias = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            _dia_payload("dia-1", "2026-07-20T22:00:00Z"),
            _dia_payload("dia-2", "2026-07-21T22:00:00Z"),
            _dia_payload("dia-3", "2026-07-22T22:00:00Z"),
        ],
    ).json()
    gasto = client.post(
        f"/dias/{dias[0]['id']}/gastos", json=_gasto_payload()
    ).json()
    session.expire_all()
    return ciclo, dias, gasto


def test_relatorio_csv_escreve_o_dia_de_calendario(ambiente):  # noqa: F811
    """Em UTC+2 o primeiro dia saía "20/07/2026" (o dia UTC do instante);
    agora sai o dia de calendário que o aparelho quis dizer."""
    client = ambiente.como(USER_A)
    ciclo, _, _ = _viagem_em_paris(client, ambiente.session)

    response = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert response.status_code == 200
    texto = response.content.decode("utf-8-sig")
    assert "21/07/2026" in texto
    assert "20/07/2026" not in texto


def test_relatorio_pdf_escreve_o_dia_de_calendario(ambiente):  # noqa: F811
    import pypdfium2 as pdfium
    from services import export_service
    from services.pdfium_seguro import trava_pdfium

    client = ambiente.como(USER_A)
    ciclo, _, _ = _viagem_em_paris(client, ambiente.session)
    ciclo_db = ambiente.session.get(models.Ciclo, ciclo["id"])

    agora = datetime(2026, 11, 25, 20, 40, tzinfo=export_service.FUSO_BRASIL)
    pdf = export_service.gerar_pdf(ciclo_db, agora=agora)

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

    assert "21/07/2026" in texto
    assert "20/07/2026" not in texto


def test_marcar_previa_casa_compra_com_o_dia_de_calendario(ambiente):  # noqa: F811
    """A compra de 23/07 pertence ao dia 23/07 da viagem; lendo o instante em
    UTC (22/07) ela caía fora da viagem inteira."""
    from dtos.fatura import CompraLida, FaturaLida
    from services import fatura_service

    client = ambiente.como(USER_A)
    ciclo, dias, _ = _viagem_em_paris(client, ambiente.session)

    lida = FaturaLida(
        vencimento=date(2026, 8, 5),
        compras=[
            CompraLida(
                indice=0,
                data=date(2026, 7, 23),
                descricao="HOTEL PARIS",
                valor=Decimal("500.00"),
            )
        ],
    )

    fatura_service.marcar_previa(ambiente.session, USER_A, ciclo["id"], lida)

    compra = lida.compras[0]
    assert compra.dentro_da_viagem is True
    assert compra.dia_id == dias[2]["id"]


def test_data_gasto_le_data_do_dia(ambiente):  # noqa: F811
    from services import open_finance_reconciliation_service as ofr

    client = ambiente.como(USER_A)
    _, dias, gasto = _viagem_em_paris(client, ambiente.session)

    gasto_db = ambiente.session.get(models.Gasto, gasto["id"])
    assert ofr._data_gasto(gasto_db) == date(2026, 7, 21)

    dia_db = ambiente.session.get(models.Dia, dias[0]["id"])
    dia_db.data_dia = None
    ambiente.session.expire_all()
    assert ofr._data_gasto(gasto_db) == date(2026, 7, 21)


# ------------------------------------------------------------ migration


def test_migration_backfill_pela_hora_utc_e_downgrade_sem_perda(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path}/data_dia.db")
    with engine.begin() as conexao:
        conexao.execute(
            text(
                "CREATE TABLE dias ("
                "id INTEGER PRIMARY KEY, "
                "client_id VARCHAR(50), "
                "ciclo_id INTEGER, "
                "data DATETIME, "
                "saldo NUMERIC(10,2))"
            )
        )
        conexao.execute(
            text(
                "INSERT INTO dias (client_id, ciclo_id, data, saldo) VALUES "
                "('utc0', 1, '2026-07-21 00:00:00', 100.00), "
                "('brasil', 1, '2026-07-21 03:00:00', 100.00), "
                "('paris', 1, '2026-07-20 22:00:00', 100.00)"
            )
        )

    _executar_migracao(engine, "upgrade")

    with engine.connect() as conexao:
        linhas = {
            client_id: (data, data_dia)
            for client_id, data, data_dia in conexao.execute(
                text("SELECT client_id, data, data_dia FROM dias")
            )
        }
    assert linhas["utc0"] == ("2026-07-21 00:00:00", "2026-07-21")
    assert linhas["brasil"] == ("2026-07-21 03:00:00", "2026-07-21")
    assert linhas["paris"] == ("2026-07-20 22:00:00", "2026-07-21")

    indices = {
        indice["name"] for indice in inspect(engine).get_indexes("dias")
    }
    assert "ix_dia_ciclo_data_dia" in indices

    _executar_migracao(engine, "downgrade")

    with engine.connect() as conexao:
        colunas = {
            linha[1] for linha in conexao.execute(
                text("PRAGMA table_info(dias)")
            )
        }
        datas = {
            linha[0]
            for linha in conexao.execute(text("SELECT data FROM dias"))
        }
    assert "data_dia" not in colunas
    # `data` segue intacta: nada do que já existia se perde no downgrade.
    assert datas == {
        "2026-07-21 00:00:00",
        "2026-07-21 03:00:00",
        "2026-07-20 22:00:00",
    }

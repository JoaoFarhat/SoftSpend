"""Data do dia como data de calendário (spec `docs/data-do-dia.md`, tarefa D1).

`dias.data` guarda a meia-noite local do aparelho como instante UTC; as
contas do servidor que liam `.date()` erravam um dia nos fusos a leste de
Greenwich. A coluna `dias.data_dia` e o `data_local` do fio corrigem isso:
app novo manda a data de calendário, app antigo e linhas antigas caem na
heurística da hora UTC (>= 11h → dia seguinte).

Mesmo padrão de `test_core_api.py` (SQLite em `tmp_path`, overrides de
`get_db`/`get_current_user_id`) e de `test_fatura_s2.py` para a migration.
"""

import importlib.util
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text

import models
from services.dia_calendario import data_do_dia, dia_de_calendario
from test_core_api import (  # noqa: F401  (`ambiente` é o fixture do core)
    USER_A,
    _ciclo_payload,
    _dia_payload,
    _gasto_payload,
    ambiente,
)


def _criar_ciclo(client) -> dict:
    resposta = client.post("/ciclos", json=_ciclo_payload())
    assert resposta.status_code == 200
    return resposta.json()


# ---------------------------------------------------------- dia_de_calendario


@pytest.mark.parametrize(
    "instante,esperado",
    [
        # UTC puro: mesmo dia.
        ("2026-07-21T00:00:00Z", date(2026, 7, 21)),
        # Brasil (UTC-3): 03:00Z é a meia-noite local do mesmo dia.
        ("2026-07-21T03:00:00Z", date(2026, 7, 21)),
        # Havaí (UTC-10): 10:00Z ainda conta como mesmo dia.
        ("2026-07-21T10:00:00Z", date(2026, 7, 21)),
        # Corte em 11h: a partir daqui o aparelho estava a leste de
        # Greenwich e o dia local é o dia UTC seguinte.
        ("2026-07-20T11:00:00Z", date(2026, 7, 21)),
        # Paris (UTC+2): 22:00Z é a meia-noite local do dia seguinte.
        ("2026-07-20T22:00:00Z", date(2026, 7, 21)),
        # Índia (UTC+5:30): meia hora também revela o deslocamento.
        ("2026-07-20T18:30:00Z", date(2026, 7, 21)),
    ],
)
def test_dia_de_calendario_pela_hora_utc(instante, esperado):
    v = datetime.fromisoformat(instante.replace("Z", "+00:00"))
    assert dia_de_calendario(v) == esperado


def test_dia_de_calendario_aceita_instante_sem_fuso():
    """O MySQL devolve `data` sem `tzinfo`: o valor já é UTC."""
    assert dia_de_calendario(datetime(2026, 7, 20, 22, 0)) == date(2026, 7, 21)


def test_data_do_dia_prefere_data_dia_e_cai_no_fallback():
    dia = models.Dia(
        data=datetime(2026, 7, 20, 22, 0, tzinfo=timezone.utc),
        data_dia=date(2026, 7, 25),
    )
    assert data_do_dia(dia) == date(2026, 7, 25)

    dia.data_dia = None
    assert data_do_dia(dia) == date(2026, 7, 21)

    dia.data = None
    assert data_do_dia(dia) is None


# ------------------------------------------------------------------ entrada


def test_post_dia_com_data_local_desacordo_grava_data_local(ambiente):  # noqa: F811
    """`data_local` manda: mesmo em desacordo com o instante, `data_dia`
    recebe a data de calendário e `data` segue gravado como veio."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-21T03:00:00Z",
            "data_local": "2026-07-25",
        },
    )

    assert resposta.status_code == 200, resposta.text
    assert resposta.json()["data_local"] == "2026-07-25"

    dia = ambiente.session.query(models.Dia).one()
    assert dia.data_dia == date(2026, 7, 25)
    # `data` segue gravado como veio (SQLite pode devolver com ou sem fuso).
    assert dia.data.replace(tzinfo=None) == datetime(2026, 7, 21, 3, 0)


def test_post_dia_sem_data_local_usa_heuristica(ambiente):  # noqa: F811
    """App antigo (só `data`): 22:00Z é meia-noite local do dia seguinte."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={"client_id": "dia-1", "data": "2026-07-20T22:00:00Z"},
    )

    assert resposta.status_code == 200, resposta.text
    assert resposta.json()["data_local"] == "2026-07-21"

    dia = ambiente.session.query(models.Dia).one()
    assert dia.data_dia == date(2026, 7, 21)


def test_dias_lote_misto_com_e_sem_data_local(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias/lote",
        json=[
            {
                "client_id": "dia-com",
                "data": "2026-07-21T03:00:00Z",
                "data_local": "2026-07-21",
            },
            _dia_payload("dia-sem", "2026-07-21T22:00:00Z"),
        ],
    )

    assert resposta.status_code == 200, resposta.text
    corpo = resposta.json()
    assert corpo[0]["data_local"] == "2026-07-21"
    # Sem `data_local`: 22:00Z vira o dia seguinte pela heurística.
    assert corpo[1]["data_local"] == "2026-07-22"

    dias = {
        dia.client_id: dia
        for dia in ambiente.session.query(models.Dia).all()
    }
    assert dias["dia-com"].data_dia == date(2026, 7, 21)
    assert dias["dia-sem"].data_dia == date(2026, 7, 22)


def test_reenvio_nao_recalcula_data_dia(ambiente):  # noqa: F811
    """Reenvio devolve o existente: um `data_local` diferente no segundo
    pedido não regrava `data_dia`."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    primeiro = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-21T03:00:00Z",
            "data_local": "2026-07-21",
        },
    )
    segundo = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-21T03:00:00Z",
            "data_local": "2026-07-30",
        },
    )

    assert segundo.status_code == 200
    assert segundo.json()["id"] == primeiro.json()["id"]
    assert segundo.json()["data_local"] == "2026-07-21"
    dia = ambiente.session.query(models.Dia).one()
    assert dia.data_dia == date(2026, 7, 21)


def test_data_local_fora_do_intervalo_retorna_422(ambiente):  # noqa: F811
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)

    resposta = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json={
            "client_id": "dia-1",
            "data": "2026-07-21T03:00:00Z",
            "data_local": "2036-07-21",
        },
    )

    assert resposta.status_code == 422


def test_get_dias_sem_data_dia_devolve_data_local_pela_heuristica(ambiente):  # noqa: F811
    """Linha antiga com `data_dia` nulo: a resposta calcula pelo instante."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload("dia-1", "2026-07-20T22:00:00Z"),
    ).json()

    ambiente.session.query(models.Dia).update({"data_dia": None})
    ambiente.session.commit()

    resposta = client.get(f"/ciclos/{ciclo['id']}/dias")
    assert resposta.status_code == 200
    assert resposta.json()[0]["id"] == dia["id"]
    assert resposta.json()[0]["data_local"] == "2026-07-21"


# ----------------------------------------------------------------- relatório


def test_export_csv_mostra_o_dia_de_calendario(ambiente):  # noqa: F811
    """Viagem em UTC+2 (`data` 22:00Z): o relatório sai "21/07/2026";
    antes saía 20/07, o dia UTC do instante."""
    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload("dia-1", "2026-07-20T22:00:00Z"),
    ).json()
    gasto = client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload()
    )
    assert gasto.status_code == 200

    resposta = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "csv"}
    )

    assert resposta.status_code == 200
    texto = resposta.content.decode("utf-8-sig")
    assert "21/07/2026" in texto
    assert "20/07/2026" not in texto


def test_export_pdf_mostra_o_dia_de_calendario(ambiente):  # noqa: F811
    import pypdfium2 as pdfium
    from services.pdfium_seguro import trava_pdfium

    client = ambiente.como(USER_A)
    ciclo = _criar_ciclo(client)
    dia = client.post(
        f"/ciclos/{ciclo['id']}/dias",
        json=_dia_payload("dia-1", "2026-07-20T22:00:00Z"),
    ).json()
    assert client.post(
        f"/dias/{dia['id']}/gastos", json=_gasto_payload()
    ).status_code == 200

    resposta = client.get(
        f"/ciclos/{ciclo['id']}/export", params={"formato": "pdf"}
    )
    assert resposta.status_code == 200

    with trava_pdfium:
        documento = pdfium.PdfDocument(resposta.content)
        try:
            texto = "".join(
                documento[i].get_textpage().get_text_bounded()
                for i in range(len(documento))
            )
        finally:
            documento.close()

    assert "21/07/2026" in texto
    assert "20/07/2026" not in texto


# -------------------------------------------------- prévia da fatura e match


def test_marcar_previa_casa_compra_no_dia_de_calendario(ambiente):  # noqa: F811
    """Compra de 21/07 contra dia gravado como 20/07 22:00Z (UTC+2): antes
    caía fora da viagem; agora entra em `dentro_da_viagem` e no `dia_id`."""
    from dtos.fatura import CompraLida, FaturaLida
    from services import fatura_service

    session = ambiente.session
    ciclo = models.Ciclo(id_usuario=USER_A, titulo="Viagem")
    session.add(ciclo)
    session.flush()
    dia = models.Dia(
        ciclo_id=ciclo.id,
        data=datetime(2026, 7, 20, 22, 0, tzinfo=timezone.utc),
        saldo=Decimal("100.00"),
    )
    session.add(dia)
    session.commit()

    lida = FaturaLida(
        compras=[
            CompraLida(
                indice=0,
                data=date(2026, 7, 21),
                descricao="PADARIA",
                valor=Decimal("10.00"),
            )
        ]
    )
    fatura_service.marcar_previa(session, USER_A, ciclo.id, lida)

    compra = lida.compras[0]
    assert compra.dentro_da_viagem is True
    assert compra.dia_id == dia.id


def test_data_gasto_usa_data_do_dia(ambiente):  # noqa: F811
    from services import open_finance_reconciliation_service

    session = ambiente.session
    dia = models.Dia(
        data=datetime(2026, 7, 20, 22, 0, tzinfo=timezone.utc),
        saldo=Decimal("100.00"),
    )
    gasto = models.Gasto(titulo="X", valor=Decimal("10.00"), dia=dia)
    session.add_all([dia, gasto])
    session.commit()

    # Sem `data_dia`: fallback pela heurística.
    assert open_finance_reconciliation_service._data_gasto(gasto) == date(
        2026, 7, 21
    )

    dia.data_dia = date(2026, 7, 25)
    assert open_finance_reconciliation_service._data_gasto(gasto) == date(
        2026, 7, 25
    )


# ----------------------------------------------------------------- migration


_CAMINHO_MIGRACAO = (
    Path(__file__).resolve().parents[1]
    / "alembic"
    / "versions"
    / "e4b8d2f6a1c3_dias_data_dia.py"
)

_DDL_PRE_MIGRACAO = """
CREATE TABLE ciclos (id INTEGER PRIMARY KEY, id_usuario VARCHAR(36));
CREATE TABLE dias (
    id INTEGER PRIMARY KEY,
    client_id VARCHAR(50),
    ciclo_id INTEGER REFERENCES ciclos(id),
    data DATETIME,
    saldo NUMERIC(10, 2)
);
"""


def _executar_migracao(engine, funcao: str):
    from alembic.migration import MigrationContext
    from alembic.operations import Operations

    spec = importlib.util.spec_from_file_location(
        "e4b8d2f6a1c3_migracao", _CAMINHO_MIGRACAO
    )
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    assert modulo.down_revision == "a7c3e9f1b5d2"
    with engine.connect() as conexao:
        contexto = MigrationContext.configure(conexao)
        with Operations.context(contexto):
            getattr(modulo, funcao)()
        conexao.commit()


def _banco_pre_migracao(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path}/migracao.db")
    with engine.begin() as conexao:
        for trecho in _DDL_PRE_MIGRACAO.split(";"):
            if trecho.strip():
                conexao.execute(text(trecho))
    return engine


def test_migration_backfill_pela_hora_utc(tmp_path):
    engine = _banco_pre_migracao(tmp_path)
    with engine.begin() as conexao:
        conexao.execute(
            text("INSERT INTO ciclos (id, id_usuario) VALUES (1, 'user-1')")
        )
        conexao.execute(
            text(
                "INSERT INTO dias (id, client_id, ciclo_id, data, saldo) VALUES "
                "(1, 'd-utc', 1, '2026-07-21 00:00:00', 100), "
                "(2, 'd-brasil', 1, '2026-07-21 03:00:00', 100), "
                "(3, 'd-paris', 1, '2026-07-20 22:00:00', 100), "
                "(4, 'd-nulo', 1, NULL, 100)"
            )
        )

    _executar_migracao(engine, "upgrade")

    with engine.connect() as conexao:
        linhas = dict(
            conexao.execute(text("SELECT client_id, data_dia FROM dias")).all()
        )
        assert linhas == {
            "d-utc": "2026-07-21",
            "d-brasil": "2026-07-21",
            "d-paris": "2026-07-21",
            "d-nulo": None,
        }
        indices = {
            linha[1]
            for linha in conexao.execute(text("PRAGMA index_list(dias)"))
        }
        assert "ix_dias_ciclo_data_dia" in indices


def test_migration_downgrade_nao_perde_dado(tmp_path):
    engine = _banco_pre_migracao(tmp_path)
    with engine.begin() as conexao:
        conexao.execute(
            text(
                "INSERT INTO dias (id, ciclo_id, data, saldo) "
                "VALUES (1, 1, '2026-07-20 22:00:00', 100)"
            )
        )

    _executar_migracao(engine, "upgrade")
    _executar_migracao(engine, "downgrade")

    with engine.connect() as conexao:
        colunas = {
            linha[1]
            for linha in conexao.execute(text("PRAGMA table_info(dias)"))
        }
        assert "data_dia" not in colunas
        assert conexao.execute(
            text("SELECT data FROM dias WHERE id = 1")
        ).scalar() == "2026-07-20 22:00:00"

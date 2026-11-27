"""Migrations do Alembic num MySQL de verdade (job `migrations-mysql` do CI).

O resto da suíte usa SQLite, mas o merge na `main` aplica a migration direto
no MySQL da produção — o ramo MySQL do backfill de `dias.data_dia`
(`b8e4d2f6a1c3`, `IF(HOUR(data) >= 11, ...)`) nunca tinha rodado num MySQL
antes de ir para o ar. Sem `MYSQL_TESTE_URL` o teste pula inteiro, então
nada muda no Windows/dev local.

Cenário (mesma ideia do `test_migration_backfill_pela_hora_utc_e_downgrade_sem_perda`
em `test_data_do_dia.py`, agora pela cadeia inteira do Alembic): sobe o
schema atual com `Base.metadata.create_all`, carimba `head`, desce para
`a7c3e9f1b5d2` (a coluna `data_dia` some), insere dias com `data` em várias
horas UTC, sobe de volta para `head` e confere o `data_dia` calculado pelo
ramo MySQL. Por fim desce até `e8a2b5c7d9f1` e sobe de novo — cobre as 3
últimas migrations nos dois sentidos.
"""

import os
from datetime import date
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text

_PASTA = Path(__file__).resolve().parents[1]
_INI = _PASTA / "alembic" / "alembic.ini"
_URL = os.getenv("MYSQL_TESTE_URL")

_HEAD = "b8e4d2f6a1c3"


@pytest.fixture
def mysql(monkeypatch):
    """Banco MySQL vazio com o schema atual, já carimbado em `head`.

    O `alembic/env.py` lê a URL de `database.py`: `DATABASE_URL` no ambiente
    cobre o primeiro import, e o `setattr` cobre o módulo já importado por
    outro teste do mesmo processo (o env.py a lê de novo a cada comando).
    """
    if not _URL:
        pytest.skip("MYSQL_TESTE_URL não definida (só roda no CI)")
    monkeypatch.syspath_prepend(str(_PASTA))
    monkeypatch.setenv("DATABASE_URL", _URL)
    import database
    # Sem importar os models o `Base.metadata` fica vazio (quando este teste
    # roda sozinho) e o `create_all` não cria tabela nenhuma.
    import models  # noqa: F401

    monkeypatch.setattr(database, "DATABASE_URL", _URL)

    engine = create_engine(_URL)
    database.Base.metadata.create_all(engine)
    yield engine
    engine.dispose()


def _config() -> Config:
    return Config(str(_INI))


def _data_dia_por_client_id(engine) -> dict:
    with engine.connect() as conexao:
        return {
            client_id: data_dia
            for client_id, data_dia in conexao.execute(
                text("SELECT client_id, data_dia FROM dias")
            )
        }


def test_migrations_num_mysql_de_verdade(mysql):
    config = _config()
    command.stamp(config, "head")
    command.downgrade(config, "a7c3e9f1b5d2")

    with mysql.begin() as conexao:
        conexao.execute(
            text(
                "INSERT INTO users (id, nome, username, email, senha_hash) "
                "VALUES ('user-m', 'M', 'user_m', 'm@example.com', 'hash')"
            )
        )
        conexao.execute(
            text(
                "INSERT INTO ciclos (id, client_id, valor_total, titulo, "
                "periodo, diaria, id_usuario) VALUES "
                "(1, 'ciclo-m', 700.00, 'Viagem', '21/07 a 25/07', 100.00, "
                "'user-m')"
            )
        )
        conexao.execute(
            text(
                "INSERT INTO dias (client_id, ciclo_id, data) VALUES "
                "('h00', 1, '2026-07-21 00:00:00'), "
                "('h03', 1, '2026-07-21 03:00:00'), "
                "('h10', 1, '2026-07-21 10:00:00'), "
                "('h11', 1, '2026-07-21 11:00:00'), "
                "('h22', 1, '2026-07-21 22:00:00')"
            )
        )
        colunas = {
            coluna["name"]: coluna
            for coluna in inspect(mysql).get_columns("dias")
        }
        if colunas["data"]["nullable"]:
            conexao.execute(
                text(
                    "INSERT INTO dias (client_id, ciclo_id, data) "
                    "VALUES ('sem-data', 1, NULL)"
                )
            )

    command.upgrade(config, "head")

    # O corte da heurística (hora UTC >= 11) fica entre h10 e h11.
    esperado = {
        "h00": date(2026, 7, 21),
        "h03": date(2026, 7, 21),
        "h10": date(2026, 7, 21),
        "h11": date(2026, 7, 22),
        "h22": date(2026, 7, 22),
    }
    if colunas["data"]["nullable"]:
        esperado["sem-data"] = None
    assert _data_dia_por_client_id(mysql) == esperado

    # Ida e volta das 3 últimas migrations (f2c4e6a8b0d2, a7c3e9f1b5d2,
    # b8e4d2f6a1c3) sem erro; o backfill do data_dia se repete igual.
    command.downgrade(config, "e8a2b5c7d9f1")
    command.upgrade(config, "head")

    assert _data_dia_por_client_id(mysql) == esperado
    with mysql.connect() as conexao:
        versao = conexao.execute(
            text("SELECT version_num FROM alembic_version")
        ).scalar()
    assert versao == _HEAD

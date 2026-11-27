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
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import make_url

_PASTA = Path(__file__).resolve().parents[1]
_INI = _PASTA / "alembic" / "alembic.ini"
_URL = os.getenv("MYSQL_TESTE_URL")


def _banco_e_de_teste(url: str) -> bool:
    """Só deixa rodar num banco com "teste" no nome.

    O teste faz `create_all` e `downgrade`, que apagariam as tabelas de um
    banco de verdade se alguém apontar a `MYSQL_TESTE_URL` para ele por
    engano.
    """
    try:
        banco = make_url(url).database
    except Exception:
        return False
    return bool(banco) and "teste" in banco


@pytest.fixture
def mysql(monkeypatch):
    """Banco MySQL vazio com o schema atual, já carimbado em `head`.

    O `alembic/env.py` lê a URL de `database.py`: `DATABASE_URL` no ambiente
    cobre o primeiro import, e o `setattr` cobre o módulo já importado por
    outro teste do mesmo processo (o env.py a lê de novo a cada comando).
    """
    if not _URL:
        pytest.skip("MYSQL_TESTE_URL não definida (só roda no CI)")
    if not _banco_e_de_teste(_URL):
        pytest.fail(
            "MYSQL_TESTE_URL aponta para um banco sem 'teste' no nome "
            f"({make_url(_URL).database!r}) — o teste apagaria as tabelas "
            "dele (create_all + downgrade)"
        )
    monkeypatch.syspath_prepend(str(_PASTA))
    monkeypatch.setenv("DATABASE_URL", _URL)
    import database
    # Sem importar os models o `Base.metadata` fica vazio (quando este teste
    # roda sozinho) e o `create_all` não cria tabela nenhuma.
    import models  # noqa: F401

    monkeypatch.setattr(database, "DATABASE_URL", _URL)

    engine = create_engine(_URL)
    database.Base.metadata.create_all(engine)
    # Na produção a tabela `dias` nasceu antes do índice composto, então a FK
    # `ciclo_id` tem o índice próprio que o MySQL cria para ela. O `create_all`
    # já nasce com o índice composto e o MySQL o usa para a FK — sem este
    # índice o downgrade (que derruba o composto) falharia só aqui (1553).
    with engine.begin() as conexao:
        conexao.execute(text("CREATE INDEX ciclo_id ON dias (ciclo_id)"))
    yield engine
    engine.dispose()


def _config() -> Config:
    return Config(str(_INI))


def _head_atual() -> str:
    """Última migration lida do próprio Alembic, sem constante fixa.

    Com o head fixo o assert do fim do teste ficava vermelho no CI de
    qualquer PR que acrescentasse uma migration (e, se entrasse assim,
    parava o deploy da `main`). Falha com mensagem clara se o grafo
    ramificar e houver mais de uma "última" — nesse caso falta um merge
    entre os ramos das migrations.
    """
    heads = ScriptDirectory.from_config(_config()).get_heads()
    if len(heads) != 1:
        pytest.fail(
            f"O Alembic tem {len(heads)} heads ({sorted(heads)}), não uma "
            "última migration só — falta um merge entre os ramos"
        )
    return heads[0]


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
    assert versao == _head_atual()


def test_head_atual_e_uma_so_e_nao_e_pai_de_ninguem():
    """Roda sem MySQL: o head é único e fecha a cadeia de versions/."""
    head = _head_atual()
    script = ScriptDirectory.from_config(_config())
    filhos = [
        rev.revision
        for rev in script.walk_revisions()
        if rev.down_revision is not None
        and head
        in (
            rev.down_revision
            if isinstance(rev.down_revision, tuple)
            else (rev.down_revision,)
        )
    ]
    assert not filhos, f"{head} é down_revision de {filhos}"


def test_banco_sem_teste_no_nome_e_recusado():
    assert not _banco_e_de_teste("mysql+pymysql://u:s@127.0.0.1:3306/softspend")


def test_banco_com_teste_no_nome_e_aceito():
    assert _banco_e_de_teste(
        "mysql+pymysql://u:s@127.0.0.1:3306/softspend_teste"
    )


def test_url_sem_banco_e_recusada():
    assert not _banco_e_de_teste("mysql+pymysql://u:s@127.0.0.1:3306")

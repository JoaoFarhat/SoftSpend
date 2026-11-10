"""Sessao do access token: logout e reuso de refresh token derrubam na hora.

Passa pela camada de auth real (rotas /auth/* e get_current_user), com SQLite
em `tmp_path` e um `get_db` que faz commit/rollback como o de producao.
"""

import importlib
import importlib.util
import sys
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

SENHA = "Senha123!"
ROTA_PROTEGIDA = "/usuario/ciclos"


def _app(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    sys.modules.pop("main", None)
    return importlib.import_module("main").app


@pytest.fixture
def client(monkeypatch, tmp_path):
    from database import Base, get_db
    import limiter as limiter_module

    app = _app(monkeypatch)
    monkeypatch.setattr(limiter_module.limiter, "enabled", False)

    engine = create_engine(f"sqlite:///{tmp_path}/auth.db")
    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine)

    def override_db():
        db = SessionLocal()
        try:
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_db
    try:
        with TestClient(app) as c:
            c.post(
                "/auth/register",
                json={
                    "nome": "Teste",
                    "username": "usuario_teste",
                    "email": "teste@example.com",
                    "senha": SENHA,
                },
            ).raise_for_status()
            yield c
    finally:
        app.dependency_overrides.clear()
        engine.dispose()


def _login(client) -> dict:
    resp = client.post(
        "/auth/login", json={"email": "teste@example.com", "senha": SENHA}
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _refresh(client, refresh_token: str):
    return client.post("/auth/refresh", json={"refresh_token": refresh_token})


def _status(client, access_token: str) -> int:
    return client.get(
        ROTA_PROTEGIDA, headers={"Authorization": f"Bearer {access_token}"}
    ).status_code


def _auth_service():
    # Usa o mesmo modulo que get_current_user (outros testes reimportam
    # services.auth_service, entao `from services import auth_service` pode
    # apontar para outra copia).
    return sys.modules["dependencies"].auth_service


def test_access_token_carrega_sid(client):
    sessao = _login(client)
    auth_service = _auth_service()
    payload = jwt.decode(
        sessao["access_token"],
        auth_service.SECRET_KEY,
        algorithms=[auth_service.ALGORITHM],
        audience=auth_service.JWT_AUDIENCE,
    )
    assert payload["sid"]


def test_logout_derruba_access_token_na_hora(client):
    sessao = _login(client)
    assert _status(client, sessao["access_token"]) == 200

    resp = client.post("/auth/logout", json={"refresh_token": sessao["refresh_token"]})
    assert resp.status_code == 204

    assert _status(client, sessao["access_token"]) == 401


def test_rotacao_mantem_access_tokens_antigo_e_novo(client):
    sessao = _login(client)
    resp = _refresh(client, sessao["refresh_token"])
    assert resp.status_code == 200, resp.text
    nova = resp.json()

    assert _status(client, sessao["access_token"]) == 200
    assert _status(client, nova["access_token"]) == 200


def test_logout_com_refresh_ja_rotacionado_derruba_a_sessao(client):
    sessao = _login(client)
    nova = _refresh(client, sessao["refresh_token"]).json()

    client.post("/auth/logout", json={"refresh_token": sessao["refresh_token"]})

    assert _status(client, sessao["access_token"]) == 401
    assert _status(client, nova["access_token"]) == 401
    assert _refresh(client, nova["refresh_token"]).status_code == 401


def test_reuso_de_refresh_derruba_todos_os_access_tokens(client):
    sessao_a = _login(client)
    sessao_b = _login(client)
    rotacionada = _refresh(client, sessao_a["refresh_token"]).json()

    # Reapresentar o refresh token ja rotacionado indica vazamento.
    assert _refresh(client, sessao_a["refresh_token"]).status_code == 401

    for token in (
        sessao_a["access_token"],
        rotacionada["access_token"],
        sessao_b["access_token"],
    ):
        assert _status(client, token) == 401


def test_token_sem_sid_ainda_passa(client):
    sessao = _login(client)
    auth_service = _auth_service()
    user_id = auth_service.validar_token(sessao["access_token"])
    token_antigo = auth_service.criar_access_token(user_id)

    assert "sid" not in jwt.decode(token_antigo, options={"verify_signature": False})
    assert _status(client, token_antigo) == 200


def test_logout_nao_derruba_outra_sessao_do_mesmo_usuario(client):
    sessao_a = _login(client)
    sessao_b = _login(client)

    client.post("/auth/logout", json={"refresh_token": sessao_a["refresh_token"]})

    assert _status(client, sessao_a["access_token"]) == 401
    assert _status(client, sessao_b["access_token"]) == 200
    assert _refresh(client, sessao_b["refresh_token"]).status_code == 200


def test_migration_session_id_gera_sql_mysql():
    """Renderiza a migration em modo offline com o dialeto do MySQL."""
    import io
    from pathlib import Path

    from alembic.migration import MigrationContext
    from alembic.operations import Operations

    caminho = (
        Path(__file__).resolve().parent.parent
        / "alembic"
        / "versions"
        / "e8a2b5c7d9f1_add_session_id_to_refresh_tokens.py"
    )
    spec = importlib.util.spec_from_file_location("migration_session_id", caminho)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    assert migration.down_revision == "d6f1a9c3b8e4"

    buffer = io.StringIO()
    contexto = MigrationContext.configure(
        dialect_name="mysql", opts={"as_sql": True, "output_buffer": buffer}
    )
    with Operations.context(contexto):
        migration.upgrade()
    sql = buffer.getvalue()

    assert "ALTER TABLE refresh_tokens ADD COLUMN session_id VARCHAR(36)" in sql
    assert "UPDATE refresh_tokens SET session_id = id WHERE session_id IS NULL" in sql
    assert "ALTER TABLE refresh_tokens MODIFY session_id VARCHAR(36) NOT NULL" in sql
    assert "CREATE INDEX ix_refresh_tokens_session_id ON refresh_tokens (session_id)" in sql


def test_sid_de_outro_usuario_nao_vale(client):
    sessao = _login(client)
    outro = client.post(
        "/auth/register",
        json={
            "nome": "Outro",
            "username": "outro_usuario",
            "email": "outro@example.com",
            "senha": SENHA,
        },
    ).json()
    auth_service = _auth_service()
    sid = jwt.decode(sessao["access_token"], options={"verify_signature": False})["sid"]
    agora = datetime.now(timezone.utc)
    forjado = jwt.encode(
        {
            "sub": outro["id"],
            "sid": sid,
            "iat": agora,
            "exp": agora + timedelta(minutes=5),
            "iss": auth_service.JWT_ISSUER,
            "aud": auth_service.JWT_AUDIENCE,
            "type": "access",
        },
        auth_service.SECRET_KEY,
        algorithm=auth_service.ALGORITHM,
    )
    assert _status(client, forjado) == 401

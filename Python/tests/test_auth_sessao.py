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

import models

SENHA = "Senha123!"
ROTA_PROTEGIDA = "/usuario/ciclos"


def _app(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "access-secret-com-pelo-menos-32-chars!!")
    monkeypatch.setenv(
        "REFRESH_TOKEN_SECRET_KEY", "refresh-secret-com-pelo-menos-32-chars!"
    )
    monkeypatch.delenv("OPEN_FINANCE_ENABLED", raising=False)
    monkeypatch.delenv("REFRESH_REUSE_GRACE_SECONDS", raising=False)
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
            # Testes que mexem nas linhas de refresh_tokens (janela de
            # tolerancia, expiracao) usam a mesma engine da app.
            c.SessionLocal = SessionLocal
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

    # Empurra o revoked_at para alem da janela de tolerancia: um token vazado
    # reapresentado depois nao entra na excecao da janela.
    db = client.SessionLocal()
    try:
        rt = (
            db.query(models.RefreshToken)
            .filter(
                models.RefreshToken.token_hash
                == _auth_service()._hash_token(sessao_a["refresh_token"])
            )
            .one()
        )
        rt.revoked_at = rt.revoked_at - timedelta(seconds=120)
        db.commit()
    finally:
        db.close()

    # Reapresentar o refresh token ja rotacionado indica vazamento.
    assert _refresh(client, sessao_a["refresh_token"]).status_code == 401

    for token in (
        sessao_a["access_token"],
        rotacionada["access_token"],
        sessao_b["access_token"],
    ):
        assert _status(client, token) == 401


def test_reuso_dentro_da_janela_emite_par_novo_na_mesma_sessao(client):
    sessao = _login(client)
    rotacionada = _refresh(client, sessao["refresh_token"]).json()

    # Replica imediata do token ja rotacionado cai na janela de tolerancia:
    # com a sessao ainda ativa, um par novo e emitido na mesma sessao.
    resp = _refresh(client, sessao["refresh_token"])
    assert resp.status_code == 200, resp.text
    replica = resp.json()

    assert replica["refresh_token"] not in (
        sessao["refresh_token"],
        rotacionada["refresh_token"],
    )
    sid = jwt.decode(
        sessao["access_token"], options={"verify_signature": False}
    )["sid"]
    assert (
        jwt.decode(
            replica["access_token"], options={"verify_signature": False}
        )["sid"]
        == sid
    )
    for token in (
        sessao["access_token"],
        rotacionada["access_token"],
        replica["access_token"],
    ):
        assert _status(client, token) == 200
    # A sessao fica com um so refresh token valido: o da replica.
    _envelhecer_revogados(client)
    assert _refresh(client, replica["refresh_token"]).status_code == 200


def _envelhecer_revogados(client, segundos: int = 120) -> None:
    """Empurra o revoked_at de todos os refresh tokens para fora da janela."""
    db = client.SessionLocal()
    try:
        for rt in db.query(models.RefreshToken).filter(
            models.RefreshToken.revoked_at.is_not(None)
        ):
            rt.revoked_at = rt.revoked_at - timedelta(seconds=segundos)
        db.commit()
    finally:
        db.close()


def test_reuso_na_janela_cancela_o_token_da_rotacao(client):
    # Ladrao com uma copia do token antigo: o usuario renova primeiro e o
    # ladrao reapresenta a copia dentro da janela. Os dois nao podem ficar com
    # refresh tokens validos ao mesmo tempo.
    sessao = _login(client)
    do_usuario = _refresh(client, sessao["refresh_token"]).json()
    do_ladrao = _refresh(client, sessao["refresh_token"]).json()
    assert do_ladrao["refresh_token"] != do_usuario["refresh_token"]

    # Passada a janela, o token que foi cancelado dispara o alarme e derruba
    # a sessao inteira, inclusive a cadeia de quem reapresentou.
    _envelhecer_revogados(client)
    assert _refresh(client, do_usuario["refresh_token"]).status_code == 401
    assert _refresh(client, do_ladrao["refresh_token"]).status_code == 401
    for token in (do_usuario["access_token"], do_ladrao["access_token"]):
        assert _status(client, token) == 401


def test_reuso_repetido_na_janela_deixa_so_o_ultimo_token(client):
    sessao = _login(client)
    _refresh(client, sessao["refresh_token"]).raise_for_status()
    primeira = _refresh(client, sessao["refresh_token"]).json()
    segunda = _refresh(client, sessao["refresh_token"]).json()
    # So a sessao deste login (o cadastro abre outra sessao).
    sid = jwt.decode(
        sessao["access_token"], options={"verify_signature": False}
    )["sid"]

    db = client.SessionLocal()
    try:
        validos = (
            db.query(models.RefreshToken)
            .filter(
                models.RefreshToken.session_id == sid,
                models.RefreshToken.revoked_at.is_(None),
            )
            .all()
        )
        assert [rt.token_hash for rt in validos] == [
            _auth_service()._hash_token(segunda["refresh_token"])
        ]
    finally:
        db.close()
    assert primeira["refresh_token"] != segunda["refresh_token"]


def test_reuso_na_janela_depois_do_logout_revoga(client):
    sessao = _login(client)
    rotacionada = _refresh(client, sessao["refresh_token"]).json()

    resp = client.post(
        "/auth/logout", json={"refresh_token": rotacionada["refresh_token"]}
    )
    assert resp.status_code == 204

    # Dentro da janela, mas a sessao nao esta mais ativa: conta como reuso.
    assert _refresh(client, sessao["refresh_token"]).status_code == 401
    for token in (sessao["access_token"], rotacionada["access_token"]):
        assert _status(client, token) == 401


def test_janela_zero_desliga_tolerancia(client, monkeypatch):
    monkeypatch.setenv("REFRESH_REUSE_GRACE_SECONDS", "0")
    sessao = _login(client)
    rotacionada = _refresh(client, sessao["refresh_token"]).json()

    # Replica imediata: sem janela, volta ao comportamento de reuso.
    assert _refresh(client, sessao["refresh_token"]).status_code == 401
    for token in (sessao["access_token"], rotacionada["access_token"]):
        assert _status(client, token) == 401


def test_reuso_na_janela_com_refresh_novo_expirado_revoga(client):
    sessao = _login(client)
    rotacionada = _refresh(client, sessao["refresh_token"]).json()

    # Expira o refresh token emitido na rotacao: a sessao deixa de estar
    # ativa e a replica do token antigo volta a contar como reuso.
    db = client.SessionLocal()
    try:
        passado = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(
            seconds=1
        )
        db.query(models.RefreshToken).filter(
            models.RefreshToken.token_hash
            == _auth_service()._hash_token(rotacionada["refresh_token"])
        ).update({"expires_at": passado})
        db.commit()
    finally:
        db.close()

    assert _refresh(client, sessao["refresh_token"]).status_code == 401
    for token in (sessao["access_token"], rotacionada["access_token"]):
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

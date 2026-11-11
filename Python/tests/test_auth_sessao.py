"""Sessao do access token: logout e reuso de refresh token derrubam na hora.

Passa pela camada de auth real (rotas /auth/* e get_current_user), com SQLite
em `tmp_path` e um `get_db` que faz commit/rollback como o de producao.
"""

import importlib
import importlib.util
import secrets
import sys
import uuid
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
    # com a sessao ainda ativa, um par novo e emitido sem revogar nada.
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
    # O refresh token emitido na rotacao continua vivo na mesma sessao.
    assert _refresh(client, rotacionada["refresh_token"]).status_code == 200


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


def _registrar_outro(client) -> dict:
    resp = client.post(
        "/auth/register",
        json={
            "nome": "Outro",
            "username": "outro_usuario",
            "email": "outro@example.com",
            "senha": SENHA,
        },
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _inserir_refresh_token(
    db, user_id: str, *, expires_at: datetime, revoked_at: datetime | None = None
) -> str:
    rt = models.RefreshToken(
        user_id=user_id,
        session_id=str(uuid.uuid4()),
        token_hash=secrets.token_hex(32),
        expires_at=expires_at,
        revoked_at=revoked_at,
    )
    db.add(rt)
    db.flush()
    return rt.id


def _user_id_por_email(client, email: str) -> str:
    db = client.SessionLocal()
    try:
        return db.query(models.User).filter_by(email=email).one().id
    finally:
        db.close()


def _ids_refresh_tokens(client) -> set:
    db = client.SessionLocal()
    try:
        return {rt.id for rt in db.query(models.RefreshToken).all()}
    finally:
        db.close()


def _semente_tokens_expirados(client, user_a: str, user_b: str) -> dict:
    """Semeia tokens expirados/validos/revogados para A e B; devolve os ids."""
    agora = datetime.now(timezone.utc).replace(tzinfo=None)
    passado = agora - timedelta(seconds=1)
    futuro = agora + timedelta(days=1)
    db = client.SessionLocal()
    try:
        ids = {
            "a_expirado": _inserir_refresh_token(
                db, user_a, expires_at=passado
            ),
            "a_expirado_revogado": _inserir_refresh_token(
                db, user_a, expires_at=passado, revoked_at=passado
            ),
            "a_valido": _inserir_refresh_token(db, user_a, expires_at=futuro),
            "a_revogado_valido": _inserir_refresh_token(
                db, user_a, expires_at=futuro, revoked_at=agora
            ),
            "b_expirado": _inserir_refresh_token(
                db, user_b, expires_at=passado
            ),
            "b_valido": _inserir_refresh_token(db, user_b, expires_at=futuro),
        }
        db.commit()
        return ids
    finally:
        db.close()


def _assert_limpeza_so_do_usuario_a(restantes: set, ids: dict):
    assert ids["a_expirado"] not in restantes
    assert ids["a_expirado_revogado"] not in restantes
    assert {
        ids["a_valido"],
        ids["a_revogado_valido"],
        ids["b_expirado"],
        ids["b_valido"],
    } <= restantes


def test_login_apaga_apenas_os_expirados_do_proprio_usuario(client):
    outro = _registrar_outro(client)
    user_a = _user_id_por_email(client, "teste@example.com")
    ids = _semente_tokens_expirados(client, user_a, outro["id"])

    assert _login(client)["id"] == user_a

    _assert_limpeza_so_do_usuario_a(_ids_refresh_tokens(client), ids)


def test_refresh_apaga_apenas_os_expirados_do_proprio_usuario(client):
    sessao = _login(client)
    outro = _registrar_outro(client)
    ids = _semente_tokens_expirados(client, sessao["id"], outro["id"])

    resp = _refresh(client, sessao["refresh_token"])
    assert resp.status_code == 200, resp.text

    restantes = _ids_refresh_tokens(client)
    _assert_limpeza_so_do_usuario_a(restantes, ids)
    # O token usado no refresh fica revogado mas nao expirado: tem que
    # continuar na tabela para a deteccao de reuso.
    rt_rotacionado = _id_por_token_hash(client, sessao["refresh_token"])
    assert rt_rotacionado in restantes


def _id_por_token_hash(client, refresh_token: str):
    db = client.SessionLocal()
    try:
        return (
            db.query(models.RefreshToken)
            .filter(
                models.RefreshToken.token_hash
                == _auth_service()._hash_token(refresh_token)
            )
            .one()
            .id
        )
    finally:
        db.close()


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

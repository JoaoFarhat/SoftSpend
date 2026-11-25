"""Dois cadastros com o mesmo e-mail/usuário chegando ao mesmo tempo.

`auth_service.registrar` confere se o e-mail e o usuário já existem e depois
grava. Na corrida real, os dois pedidos passam juntos na conferência e o
segundo esbarra no `unique` de `users.email`/`users.username` só no `flush`
de `criar_usuario` — e o `IntegrityError` virava 500. Aqui a corrida é
simulada fazendo as buscas do repositório devolverem `None`: a resposta
precisa ser 400 e a sessão do banco seguir usável.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

import models

SENHA = "Senha123!"


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
            c.SessionLocal = SessionLocal
            yield c
    finally:
        app.dependency_overrides.clear()
        engine.dispose()


def _auth_repository():
    # O mesmo modulo que o auth_service da app usa (outros testes reimportam
    # services.auth_service, entao `from services import auth_service` pode
    # apontar para outra copia).
    return sys.modules["dependencies"].auth_service.auth_repository


def test_cadastro_em_corrida_devolve_400_e_sessao_segue_usavel(
    client, monkeypatch
):
    resp = client.post(
        "/auth/register",
        json={
            "nome": "Teste",
            "username": "usuario_teste",
            "email": "teste@example.com",
            "senha": SENHA,
        },
    )
    assert resp.status_code == 200, resp.text

    # Simula a corrida: a conferência do segundo pedido não enxerga o
    # cadastro que o primeiro ainda não comitou.
    auth_repository = _auth_repository()
    original_email = auth_repository.buscar_por_email
    original_username = auth_repository.buscar_por_username
    monkeypatch.setattr(
        auth_repository, "buscar_por_email", lambda *a, **k: None
    )
    monkeypatch.setattr(
        auth_repository, "buscar_por_username", lambda *a, **k: None
    )

    repetido = client.post(
        "/auth/register",
        json={
            "nome": "Teste",
            "username": "usuario_teste",
            "email": "teste@example.com",
            "senha": SENHA,
        },
    )
    assert repetido.status_code == 400, repetido.text
    assert repetido.json()["error"] == "Dados de cadastro ja em uso"

    db = client.SessionLocal()
    try:
        assert db.query(models.User).count() == 1
    finally:
        db.close()

    # A sessão do banco não ficou envenenada pelo IntegrityError: um
    # cadastro novo com outros dados funciona na sequência.
    monkeypatch.setattr(auth_repository, "buscar_por_email", original_email)
    monkeypatch.setattr(auth_repository, "buscar_por_username", original_username)
    outro = client.post(
        "/auth/register",
        json={
            "nome": "Outro",
            "username": "outro_usuario",
            "email": "outro@example.com",
            "senha": SENHA,
        },
    )
    assert outro.status_code == 200, outro.text

    db = client.SessionLocal()
    try:
        assert db.query(models.User).count() == 2
    finally:
        db.close()
